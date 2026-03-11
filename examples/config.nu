# 快捷命令调用封装
# 如果是windows就是minimax_cli.exe，如果是macos就是minimax_cli
def mcli [msg: string] {
  minimax_cli.exe --mcp --enable-tools --log --debug --trajectory --system '用playwright打开url' -p $msg
}