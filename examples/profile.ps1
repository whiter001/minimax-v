# symlink minimax_cli /usr/local/bin
# sudo ln -s /Users/byf/bl/github/minimax-v/minimax_cli /usr/local/bin/minimax_cli
# on macos
function mcli {
    param([string]$msg)
    minimax_cli --mcp --enable-tools --log --debug --trajectory --system '用playwright打开url' -p $msg
}