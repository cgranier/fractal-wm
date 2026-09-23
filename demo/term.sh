#!/usr/bin/env bash
# First demo window: a plain shell listing /bin. No personal prompt or history.
export PS1='demo $ ' HISTFILE=/dev/null
clear
ls --color=always -C -w 100 /bin | head -45
exec bash --norc --noprofile
