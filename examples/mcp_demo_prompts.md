# MCP Demo 场景清单（含验证提示）

本文件收集了可直接运行的 `--mcp` 场景，用于演示和回归验证。

## 前置条件

- 已编译：`bash build.sh`
- 已配置 API Key：`MINIMAX_API_KEY` 或 `~/.config/minimax/config`
- 已配置 MCP（至少包含 playwright，参考 `examples/mcp.json.example`）

## Demo 1：X 信息筛选（你提供的核心场景）

```bash
./minimax_cli --mcp -p "打开https://x.com/home获取10条消息，判断一下过滤出来对我最有价值的，然后用中文列出来告诉我具体内容"
```

验证关注点：

- 进程应正常退出（exit code 0）
- 输出中应包含中文筛选结果（如“价值”“最有价值”“过滤”等）

## Demo 2：百度打开与页面确认

```bash
./minimax_cli --mcp -p "请使用 playwright 打开百度首页，并告诉我页面标题与首页主搜索框是否可见"
```

验证关注点：

- 能成功调用 `browser_navigate` / `browser_snapshot`
- 返回包含页面标题和元素可见性描述

## Demo 3：天气页面摘要

```bash
./minimax_cli --mcp -p "打开https://nmc.cn/publish/forecast/ABJ/beijing.html 总结未来几日的天气情况，并用中文分点列出"
```

验证关注点：

- 多轮工具调用后能完成总结
- 输出包含未来几日天气趋势和温度信息

## Demo 4：技术站点信息抽取

```bash
./minimax_cli --mcp -p "打开https://news.ycombinator.com，提取前10条标题，按对开发者实用价值排序后用中文说明理由"
```

验证关注点：

- 能抓取列表并做排序
- 输出包含“排序依据/理由”

## Demo 5：GitHub 热门项目速览

```bash
./minimax_cli --mcp -p "打开https://github.com/trending，提取前10个项目并按‘值得今天关注’排序，给出中文理由"
```

验证关注点：

- 能提取项目名
- 能做价值判断并给出理由

## 批量验证

可直接运行：

```bash
bash tests/mcp_demo_verify.sh
```

脚本会自动执行一组 demo，输出通过/失败统计。
