#!/usr/bin/env bash
# On-screen key display for the demo: a floating, pinned terminal that prints
# whatever is written to the FIFO. Started by record.sh; not for daily use.
# The window is one or two rows high, so print without newlines or the text
# scrolls straight out of view.
fifo="${1:?fifo path}"
exec 3<>"$fifo"
printf '\033[?25l'
while IFS= read -r line <&3; do
  clear
  printf '  %s' "$line"
done
