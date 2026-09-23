import unittest

from tree import Box, Tree

SCREEN = Box(0, 26, 1368, 886)


def make(tree: Tree, *addrs: str):
    return [tree.add_window(a, a.upper()) for a in addrs]


class InsertRules(unittest.TestCase):
    def test_new_windows_land_beside_focus_in_root_row(self):
        t = Tree()
        a, b, c = make(t, "a", "b", "c")
        self.assertEqual([n.kind for n in t.root.children], ["desktop", "window", "window", "window"])
        self.assertIs(t.focused, c)
        t.set_focus("a")
        d = t.add_window("d")
        self.assertEqual([n.address for n in t.root.children[1:]], ["a", "d", "b", "c"])

    def test_zoomed_into_leaf_wraps_it(self):
        t = Tree(desktop=False)
        a, b = make(t, "a", "b")
        t.set_focus("a")
        t.zoom_in()
        self.assertIs(t.viewport, a)
        c = t.add_window("c")
        self.assertEqual(t.viewport.kind, "row")
        self.assertEqual([n.address for n in t.viewport.children], ["a", "c"])
        self.assertEqual([n.address for n in t.root.children[1:]], ["b"])

    def test_zoomed_into_desktop_wraps_it(self):
        t = Tree()
        make(t, "a")
        t.zoom_desktop()
        b = t.add_window("b")
        self.assertEqual(t.viewport.kind, "row")
        self.assertEqual([n.kind for n in t.viewport.children], ["desktop", "window"])
        self.assertEqual(t.layout(SCREEN).visible.keys(), {"b"})

    def test_duplicate_add_is_idempotent(self):
        t = Tree(desktop=False)
        a = t.add_window("a")
        self.assertIs(t.add_window("a", "new"), a)
        self.assertEqual(a.label, "new")


class LayoutMath(unittest.TestCase):
    def test_row_splits_width_by_weight(self):
        t = Tree(desktop=False)
        a, b = make(t, "a", "b")
        b.weight = 3
        lay = t.layout(Box(0, 0, 400, 100))
        self.assertEqual(lay.visible["a"], (0, 0, 100, 100))
        self.assertEqual(lay.visible["b"], (100, 0, 300, 100))
        self.assertEqual(lay.hidden, set())

    def test_gaps_out_on_screen_edges_and_gaps_in_between(self):
        t = Tree(desktop=False)
        make(t, "a", "b")
        lay = t.layout(Box(0, 0, 400, 100), gaps_in=3, gaps_out=5, border=2)
        self.assertEqual(lay.visible["a"], (7, 7, 200 - 7 - 5, 100 - 14))
        self.assertEqual(lay.visible["b"], (205, 7, 200 - 5 - 7, 100 - 14))

    def test_nested_column_and_tabs(self):
        t = Tree(desktop=False)
        a, b, c = make(t, "a", "b", "c")
        t.set_focus("b")
        col = t.split("column")
        d = t.add_window("d")
        self.assertIs(d.parent, col)
        t.set_layout("tabs")
        lay = t.layout(Box(0, 0, 300, 100))
        self.assertIn("d", lay.visible)
        self.assertIn("b", lay.hidden)
        self.assertEqual(lay.visible["d"], (100, 0, 100, 100))
        t.tab_cycle(1)
        lay = t.layout(Box(0, 0, 300, 100))
        self.assertIn("b", lay.visible)
        self.assertIn("d", lay.hidden)

    def test_viewport_subtree_fills_screen_and_rest_is_hidden(self):
        t = Tree(desktop=False)
        a, b, c = make(t, "a", "b", "c")
        t.set_focus("b")
        t.split("column")
        t.add_window("d")
        t.zoom_in()
        self.assertEqual(t.viewport.kind, "column")
        lay = t.layout(Box(0, 0, 300, 100))
        self.assertEqual(set(lay.visible), {"b", "d"})
        self.assertEqual(lay.hidden, {"a", "c"})
        self.assertEqual(lay.visible["b"], (0, 0, 300, 50))
        self.assertEqual(lay.visible["d"], (0, 50, 300, 50))


class Zooming(unittest.TestCase):
    def build(self):
        t = Tree(desktop=False)
        make(t, "a", "b", "c")
        t.set_focus("b")
        t.split("column")
        t.add_window("d")
        return t

    def test_zoom_in_out_history(self):
        t = self.build()
        col = t.focused.parent
        self.assertIs(t.zoom_in(), col)
        self.assertIs(t.zoom_in(), t.find_window("d"))
        self.assertIsNone(t.zoom_in())
        self.assertIs(t.zoom_out(), col)
        self.assertIs(t.back(), t.find_window("d"))
        self.assertIs(t.back(), col)
        self.assertIs(t.back(), t.root)
        self.assertIsNone(t.back())
        self.assertIs(t.forward(), col)
        self.assertIs(t.zoom_out(), t.root)
        self.assertEqual(t.forward_stack, [])

    def test_zoom_moves_focus_into_view(self):
        t = self.build()
        t.set_focus("a")
        col = t.find_window("d").parent
        t.zoom_to(col)
        self.assertEqual(t.focused.address, "b")

    def test_framings_follow_nodes_and_die_with_them(self):
        t = self.build()
        col = t.focused.parent
        t.zoom_to(col)
        t.save_framing("work")
        t.zoom_root()
        self.assertIs(t.go_framing("work"), col)
        t.remove_window("b")  # column collapses into d
        self.assertIs(t.go_framing("work"), t.find_window("d"))
        t.remove_window("d")
        self.assertIsNone(t.go_framing("work"))
        self.assertEqual(t.framings, {})

    def test_closing_viewport_leaf_returns_to_parent(self):
        t = self.build()
        t.zoom_in()
        t.zoom_in()
        self.assertEqual(t.viewport.address, "d")
        t.remove_window("d")
        self.assertIs(t.viewport, t.find_window("b"))
        self.assertEqual(t.focused.address, "b")

    def test_remove_all_windows_keeps_root(self):
        t = Tree()
        make(t, "a", "b")
        t.remove_window("a")
        t.remove_window("b")
        self.assertEqual([n.kind for n in t.root.children], ["desktop"])
        self.assertIs(t.viewport, t.root)


class Moving(unittest.TestCase):
    def test_swap_within_row(self):
        t = Tree(desktop=False)
        make(t, "a", "b", "c")
        t.set_focus("a")
        self.assertTrue(t.move("right"))
        self.assertEqual([n.address for n in t.root.children], ["b", "a", "c"])
        self.assertTrue(t.move("left"))
        self.assertFalse(t.move("left"))
        self.assertEqual([n.address for n in t.root.children], ["a", "b", "c"])

    def test_move_out_of_column_into_row(self):
        t = Tree(desktop=False)
        make(t, "a", "b", "c")
        t.set_focus("b")
        t.split("column")
        t.add_window("d")
        t.set_focus("d")
        self.assertTrue(t.move("right"))
        self.assertEqual([n.address for n in t.root.children], ["a", "b", "d", "c"])

    def test_move_perpendicular_wraps_root(self):
        t = Tree(desktop=False)
        make(t, "a", "b")
        t.set_focus("b")
        self.assertTrue(t.move("down"))
        self.assertEqual(t.root.kind, "row")
        self.assertEqual(len(t.root.children), 1)
        col = t.root.children[0]
        self.assertEqual(col.kind, "column")
        self.assertEqual([n.address for n in col.children], ["a", "b"])
        lay = t.layout(Box(0, 0, 100, 200))
        self.assertEqual(lay.visible["a"], (0, 0, 100, 100))
        self.assertEqual(lay.visible["b"], (0, 100, 100, 100))

    def test_insert_beside(self):
        t = Tree(desktop=False)
        a, b = make(t, "a", "b")
        c = t.add_window("c")
        t.detach_window("c")
        c = t.add_window.__self__.find_window("c")
        self.assertIsNone(c)
        from tree import Node
        leaf = Node("window", address="c")
        t.insert_beside(leaf, a, "down")
        self.assertEqual(a.parent.kind, "column")
        self.assertEqual([n.address for n in a.parent.children], ["a", "c"])
        self.assertEqual(len(t.root.children), 2)


class Persistence(unittest.TestCase):
    def test_roundtrip(self):
        t = Tree()
        make(t, "a", "b", "c")
        t.set_focus("b")
        t.split("tabs")
        t.add_window("d")
        t.zoom_in()
        t.save_framing("x")
        t.zoom_root()
        t.resize(1.5)
        text = t.dumps()
        u = Tree.loads(text)
        self.assertEqual(u.dumps(), text)
        self.assertEqual(u.layout(SCREEN).visible, t.layout(SCREEN).visible)
        self.assertEqual(u.render(), t.render())
        self.assertIn("[framing: x]", u.render())


if __name__ == "__main__":
    unittest.main()
