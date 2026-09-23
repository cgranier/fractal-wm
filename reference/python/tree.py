"""Tree model for fractal window management.

One tree per managed workspace. Leaves are windows (or the desktop); interior
nodes are containers (row, column, tabs). Any node can be the *viewport*: the
node whose box is mapped onto the monitor. Everything outside the viewport's
subtree is hidden (parked by the daemon). No Hyprland calls live here, so the
whole module is testable with plain unittest.
"""

from __future__ import annotations

import json
import secrets
from dataclasses import dataclass, field
from typing import Iterator, Optional

CONTAINERS = ("row", "column", "tabs")
LEAVES = ("window", "desktop")
HORIZONTAL = ("left", "right")
VERTICAL = ("up", "down")

MIN_WEIGHT = 0.2
MAX_WEIGHT = 5.0


def new_id() -> str:
    return secrets.token_hex(2)


@dataclass
class Box:
    x: float
    y: float
    w: float
    h: float

    def rounded(self) -> tuple[int, int, int, int]:
        x0 = round(self.x)
        y0 = round(self.y)
        x1 = round(self.x + self.w)
        y1 = round(self.y + self.h)
        return x0, y0, max(1, x1 - x0), max(1, y1 - y0)


@dataclass
class Node:
    kind: str
    id: str = field(default_factory=new_id)
    children: list["Node"] = field(default_factory=list)
    parent: Optional["Node"] = field(default=None, repr=False, compare=False)
    weight: float = 1.0
    address: Optional[str] = None
    label: str = ""
    active: int = 0  # tabs: index of the visible child

    # -- structure -----------------------------------------------------------
    @property
    def is_container(self) -> bool:
        return self.kind in CONTAINERS

    @property
    def is_window(self) -> bool:
        return self.kind == "window"

    def ancestors(self) -> Iterator["Node"]:
        node = self.parent
        while node is not None:
            yield node
            node = node.parent

    def walk(self) -> Iterator["Node"]:
        yield self
        for child in self.children:
            yield from child.walk()

    def windows(self) -> Iterator["Node"]:
        return (n for n in self.walk() if n.is_window)

    def contains(self, other: "Node") -> bool:
        return other is self or any(a is self for a in other.ancestors())

    def index_in_parent(self) -> int:
        assert self.parent is not None
        return next(i for i, c in enumerate(self.parent.children) if c is self)

    def add(self, child: "Node", index: Optional[int] = None) -> "Node":
        child.parent = self
        if index is None:
            self.children.append(child)
        else:
            self.children.insert(index, child)
        if self.kind == "tabs":
            self.active = child.index_in_parent()
        return child

    def remove(self, child: "Node") -> None:
        idx = child.index_in_parent()
        self.children.pop(idx)
        child.parent = None
        if self.kind == "tabs" and self.children:
            self.active = min(self.active, len(self.children) - 1)
            if idx < self.active:
                self.active -= 1

    def replace_with(self, other: "Node") -> None:
        """Swap `self` for `other` in the parent's child list, keeping the slot weight."""
        parent = self.parent
        assert parent is not None
        idx = self.index_in_parent()
        parent.children[idx] = other
        other.parent = parent
        other.weight = self.weight
        self.parent = None

    def active_child(self) -> Optional["Node"]:
        if not self.children:
            return None
        if self.kind == "tabs":
            return self.children[min(self.active, len(self.children) - 1)]
        return None

    def first_window(self) -> Optional["Node"]:
        """The window a user would expect focused when this node fills the screen."""
        if self.is_window:
            return self
        if self.kind == "tabs":
            child = self.active_child()
            return child.first_window() if child else None
        for child in self.children:
            found = child.first_window()
            if found:
                return found
        return None

    def name(self) -> str:
        if self.is_window:
            return self.label or (self.address or "?")
        if self.kind == "desktop":
            return "Desktop"
        return self.kind

    # -- serialization -------------------------------------------------------
    def to_dict(self) -> dict:
        d: dict = {"kind": self.kind, "id": self.id, "weight": self.weight}
        if self.is_window:
            d["address"] = self.address
            d["label"] = self.label
        if self.is_container:
            d["children"] = [c.to_dict() for c in self.children]
            if self.kind == "tabs":
                d["active"] = self.active
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Node":
        node = cls(
            kind=d["kind"],
            id=d.get("id") or new_id(),
            weight=float(d.get("weight", 1.0)),
            address=d.get("address"),
            label=d.get("label", ""),
            active=int(d.get("active", 0)),
        )
        for c in d.get("children", []):
            node.add(cls.from_dict(c))
        if node.kind == "tabs":
            node.active = min(node.active, max(0, len(node.children) - 1))
        return node


@dataclass
class Layout:
    visible: dict[str, tuple[int, int, int, int]]  # address -> (x, y, w, h)
    hidden: set[str]  # addresses outside the viewport or in inactive tabs


class Tree:
    def __init__(self, desktop: bool = True):
        self.root = Node("row")
        if desktop:
            self.root.add(Node("desktop"))
        self.viewport: Node = self.root
        self.focused: Optional[Node] = None
        self.back_stack: list[str] = []
        self.forward_stack: list[str] = []
        self.framings: dict[str, str] = {}

    # -- lookup --------------------------------------------------------------
    def nodes(self) -> Iterator[Node]:
        return self.root.walk()

    def find(self, node_id: str) -> Optional[Node]:
        return next((n for n in self.nodes() if n.id == node_id), None)

    def find_window(self, address: str) -> Optional[Node]:
        return next((n for n in self.nodes() if n.is_window and n.address == address), None)

    def addresses(self) -> set[str]:
        return {n.address for n in self.root.windows() if n.address}

    def desktop_node(self) -> Optional[Node]:
        return next((n for n in self.nodes() if n.kind == "desktop"), None)

    def _in_viewport(self, node: Optional[Node]) -> bool:
        return node is not None and self.viewport.contains(node)

    # -- windows -------------------------------------------------------------
    def add_window(self, address: str, label: str = "") -> Node:
        existing = self.find_window(address)
        if existing:
            existing.label = label or existing.label
            return existing
        leaf = Node("window", address=address, label=label)
        focused = self.focused if self._in_viewport(self.focused) else None

        if focused is not None and focused is not self.viewport and focused.parent is not None:
            focused.parent.add(leaf, focused.index_in_parent() + 1)
        elif self.viewport.is_container:
            self.viewport.add(leaf)
        else:
            # Zoomed all the way into a leaf (window or desktop): wrap it so the
            # newcomer lands beside it, and keep the camera on the new pair.
            self._wrap(self.viewport, "row").add(leaf)
            self.viewport = self.viewport.parent  # type: ignore[assignment]
        self.focused = leaf
        return leaf

    def remove_window(self, address: str) -> bool:
        leaf = self.find_window(address)
        if leaf is None:
            return False
        self._detach(leaf)
        return True

    def detach_window(self, address: str) -> bool:
        """Pull a window out of the tree without closing it (it stays floating)."""
        return self.remove_window(address)

    def set_focus(self, address: str) -> bool:
        leaf = self.find_window(address)
        if leaf is None:
            return False
        self.focused = leaf
        for anc in leaf.ancestors():
            if anc.kind == "tabs":
                child = next(c for c in anc.children if c.contains(leaf))
                anc.active = child.index_in_parent()
        return True

    def _detach(self, node: Node) -> None:
        parent = node.parent
        if parent is None:
            return
        parent.remove(node)
        lost_focus = self.focused is not None and node.contains(self.focused)
        if node.contains(self.viewport):
            self.viewport = parent
        for name, nid in list(self.framings.items()):
            if any(n.id == nid for n in node.walk()):
                del self.framings[name]
        self._collapse(parent)
        if lost_focus:
            self.focused = self.viewport.first_window()

    def _collapse(self, node: Node) -> None:
        """Drop empty containers and unwrap single-child ones (root excepted)."""
        while node is not self.root and node.is_container:
            parent = node.parent
            assert parent is not None
            if len(node.children) == 0:
                if self.viewport is node:
                    self.viewport = parent
                parent.remove(node)
                self.framings = {k: v for k, v in self.framings.items() if v != node.id}
                node = parent
            elif len(node.children) == 1:
                only = node.children[0]
                node.remove(only)
                node.replace_with(only)
                if self.viewport is node:
                    self.viewport = only
                self.framings = {k: (only.id if v == node.id else v) for k, v in self.framings.items()}
                node = parent
            else:
                break

    def _wrap(self, node: Node, kind: str) -> Node:
        """Put `node` inside a new container of `kind` occupying node's old slot."""
        if node is self.root:
            container = Node(kind)
            for child in list(self.root.children):
                self.root.remove(child)
                container.add(child)
            self.root.add(container)
            return container
        container = Node(kind)
        node.replace_with(container)
        node.weight = 1.0
        container.add(node)
        return container

    # -- viewport (the fractal part) ----------------------------------------
    def _push_history(self) -> None:
        self.back_stack.append(self.viewport.id)
        self.forward_stack.clear()
        del self.back_stack[:-50]

    def zoom_to(self, node: Node, record: bool = True) -> Node:
        if node is not self.viewport:
            if record:
                self._push_history()
            self.viewport = node
        if not self._in_viewport(self.focused):
            self.focused = node.first_window()
        return node

    def zoom_in(self) -> Optional[Node]:
        vp = self.viewport
        if not vp.is_container or not vp.children:
            return None
        target = next((c for c in vp.children if self.focused is not None and c.contains(self.focused)), None)
        if target is None:
            target = vp.active_child() or vp.children[0]
        return self.zoom_to(target)

    def zoom_out(self) -> Optional[Node]:
        if self.viewport.parent is None:
            return None
        return self.zoom_to(self.viewport.parent)

    def zoom_root(self) -> Node:
        return self.zoom_to(self.root)

    def zoom_desktop(self) -> Optional[Node]:
        desk = self.desktop_node()
        return self.zoom_to(desk) if desk else None

    def back(self) -> Optional[Node]:
        while self.back_stack:
            node = self.find(self.back_stack.pop())
            if node is not None:
                self.forward_stack.append(self.viewport.id)
                return self.zoom_to(node, record=False)
        return None

    def forward(self) -> Optional[Node]:
        while self.forward_stack:
            node = self.find(self.forward_stack.pop())
            if node is not None:
                self.back_stack.append(self.viewport.id)
                return self.zoom_to(node, record=False)
        return None

    def save_framing(self, name: str, node: Optional[Node] = None) -> Node:
        node = node or self.viewport
        self.framings[name] = node.id
        return node

    def go_framing(self, name: str) -> Optional[Node]:
        nid = self.framings.get(name)
        node = self.find(nid) if nid else None
        if node is None:
            self.framings.pop(name, None)
            return None
        return self.zoom_to(node)

    # -- structure edits -----------------------------------------------------
    def split(self, kind: str) -> Optional[Node]:
        """Wrap the focused leaf in a new `kind` container (i3 semantics: the next window opens inside it)."""
        if kind not in CONTAINERS:
            raise ValueError(kind)
        target = self.focused if self._in_viewport(self.focused) else None
        if target is None:
            return None
        if target.parent is not None and target.parent.kind == kind and len(target.parent.children) == 1:
            return target.parent
        container = self._wrap(target, kind)
        if self.viewport is target:
            self.viewport = container
        return container

    def set_layout(self, kind: str) -> Optional[Node]:
        """Change the kind of the container around the focused leaf (or the viewport itself)."""
        if kind not in CONTAINERS:
            raise ValueError(kind)
        target = self.focused if self._in_viewport(self.focused) else None
        container = target.parent if (target is not None and target is not self.viewport) else self.viewport
        if container is None or not container.is_container:
            return None
        container.kind = kind
        if kind == "tabs" and target is not None and target.parent is container:
            container.active = target.index_in_parent()
        return container

    def move(self, direction: str) -> bool:
        """Move the focused leaf one step in a direction, i3-style.

        1. Swap with the neighbouring sibling when the parent already runs that way.
        2. Otherwise climb to the nearest ancestor (inside the viewport) that runs that
           way and step out beside the branch we came from.
        3. Otherwise wrap the viewport in a container running that way and move out.
        """
        leaf = self.focused if self._in_viewport(self.focused) else None
        if leaf is None or leaf is self.viewport or leaf.parent is None:
            return False
        want = "row" if direction in HORIZONTAL else "column"
        forward = direction in ("right", "down")
        parent = leaf.parent

        def runs(container: Node) -> bool:
            return container.kind == want or (container.kind == "tabs" and want == "row")

        if runs(parent):
            idx = leaf.index_in_parent()
            nidx = idx + (1 if forward else -1)
            if 0 <= nidx < len(parent.children):
                parent.children[idx], parent.children[nidx] = parent.children[nidx], parent.children[idx]
                if parent.kind == "tabs":
                    parent.active = nidx
                return True

        branch = leaf
        while branch is not self.viewport and branch.parent is not None:
            anc = branch.parent
            if anc.kind == want and branch is not leaf:
                idx = branch.index_in_parent()
                parent.remove(leaf)
                anc.add(leaf, idx + 1 if forward else idx)
                self._collapse(parent)
                return True
            branch = anc

        vp = self.viewport
        if vp.kind == want and parent is vp:
            return False  # already at the edge of the viewport in that direction
        if vp is self.root and self.root.kind == want:
            container = self.root
        else:
            # Take the leaf out first: wrapping the root re-parents its children.
            parent.remove(leaf)
            container = self._wrap(vp, want)
            if vp is not self.root:
                self.viewport = container
            container.add(leaf, len(container.children) if forward else 0)
            self._collapse(parent)
            return True
        parent.remove(leaf)
        container.add(leaf, len(container.children) if forward else 0)
        self._collapse(parent)
        return True

    def insert_beside(self, leaf: Node, target: Node, direction: str) -> None:
        """Dock `leaf` next to `target` on the given side, creating a container if needed."""
        want = "row" if direction in HORIZONTAL else "column"
        after = direction in ("right", "down")
        parent = target.parent
        if parent is not None and parent.kind == want:
            parent.add(leaf, target.index_in_parent() + (1 if after else 0))
            return
        container = self._wrap(target, want)
        if self.viewport is target:
            self.viewport = container
        container.add(leaf, 1 if after else 0)

    def tab_cycle(self, delta: int) -> Optional[Node]:
        start = self.focused if self._in_viewport(self.focused) else self.viewport
        tabs = next((n for n in ([start] + list(start.ancestors())) if n.kind == "tabs" and self.viewport.contains(n)), None)
        if tabs is None or not tabs.children:
            return None
        tabs.active = (tabs.active + delta) % len(tabs.children)
        child = tabs.children[tabs.active]
        self.focused = child.first_window() or self.focused
        return child

    def resize(self, factor: float) -> Optional[Node]:
        leaf = self.focused if self._in_viewport(self.focused) else None
        if leaf is None or leaf is self.viewport:
            return None
        leaf.weight = min(MAX_WEIGHT, max(MIN_WEIGHT, leaf.weight * factor))
        return leaf

    # -- layout --------------------------------------------------------------
    def layout(self, box: Box, gaps_in: float = 0, gaps_out: float = 0, border: float = 0) -> Layout:
        visible: dict[str, tuple[int, int, int, int]] = {}
        outer = Box(box.x, box.y, box.w, box.h)

        def place(node: Node, b: Box) -> None:
            if node.is_window and node.address:
                left = gaps_out if abs(b.x - outer.x) < 0.5 else gaps_in
                top = gaps_out if abs(b.y - outer.y) < 0.5 else gaps_in
                right = gaps_out if abs(b.x + b.w - (outer.x + outer.w)) < 0.5 else gaps_in
                bottom = gaps_out if abs(b.y + b.h - (outer.y + outer.h)) < 0.5 else gaps_in
                inner = Box(
                    b.x + left + border,
                    b.y + top + border,
                    b.w - left - right - 2 * border,
                    b.h - top - bottom - 2 * border,
                )
                visible[node.address] = inner.rounded()
                return
            if not node.is_container or not node.children:
                return
            if node.kind == "tabs":
                child = node.active_child()
                if child:
                    place(child, b)
                return
            total = sum(c.weight for c in node.children)
            offset = 0.0
            for child in node.children:
                share = child.weight / total
                if node.kind == "row":
                    place(child, Box(b.x + offset * b.w, b.y, share * b.w, b.h))
                    offset += share
                else:
                    place(child, Box(b.x, b.y + offset * b.h, b.w, share * b.h))
                    offset += share

        place(self.viewport, outer)
        hidden = {a for a in self.addresses() if a not in visible}
        return Layout(visible=visible, hidden=hidden)

    # -- persistence & display ------------------------------------------------
    def to_dict(self) -> dict:
        return {
            "root": self.root.to_dict(),
            "viewport": self.viewport.id,
            "focused": self.focused.address if self.focused else None,
            "back": self.back_stack,
            "forward": self.forward_stack,
            "framings": self.framings,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Tree":
        tree = cls(desktop=False)
        tree.root = Node.from_dict(d["root"])
        tree.viewport = tree.find(d.get("viewport", "")) or tree.root
        tree.focused = tree.find_window(d["focused"]) if d.get("focused") else None
        tree.back_stack = list(d.get("back", []))
        tree.forward_stack = list(d.get("forward", []))
        tree.framings = dict(d.get("framings", {}))
        return tree

    def dumps(self) -> str:
        return json.dumps(self.to_dict(), indent=1)

    @classmethod
    def loads(cls, text: str) -> "Tree":
        return cls.from_dict(json.loads(text))

    def path(self, node: Optional[Node] = None) -> list[Node]:
        node = node or self.viewport
        return list(reversed([node] + list(node.ancestors())))

    def render(self) -> str:
        lines: list[str] = []
        framing_names = {v: k for k, v in self.framings.items()}

        def walk(node: Node, depth: int) -> None:
            marks = ""
            if node is self.viewport:
                marks += " <== viewport"
            if node is self.focused:
                marks += " (focused)"
            if node.id in framing_names:
                marks += f" [framing: {framing_names[node.id]}]"
            extra = ""
            if node.kind == "tabs":
                extra = f" active={node.active}"
            if node.weight != 1.0:
                extra += f" w={node.weight:.2f}"
            lines.append(f"{'  ' * depth}{node.id} {node.name()}{extra}{marks}")
            for child in node.children:
                walk(child, depth + 1)

        walk(self.root, 0)
        return "\n".join(lines)
