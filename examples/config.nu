# 快捷命令调用封装
# 如果是windows就是minimax_cli.exe，如果是macos就是minimax_cli
def mi [msg: string] {
  minimax_cli --auto-skills  --enable-tools --log --debug --trajectory -system '你是各个领域的专家，给你的任务都可以很好的帮我执行完成' -p $msg
}
# 多mcp版本的调用封装
def ma [msg: string] {
  minimax_cli --auto-skills --mcp --enable-tools --log --debug --trajectory --system '用playwright打开url,你是各个领域的专家，给你的任务都可以很好的帮我执行完成' -p $msg
}