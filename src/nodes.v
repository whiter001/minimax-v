/**
 * nodes.v - 计算节点系统（DAG 工作流）
 *
 * 将复杂任务分解为计算节点，支持有向无环图（DAG）执行。
 * - 支持节点链式执行
 * - DAG 拓扑排序验证
 * - 循环检测
 * - 错误传播
 */

pub struct ComputeNode {
pub mut:
	id          string
	name        string
	input_type  string                    // 输入类型描述
	output_type string                    // 输出类型描述
	compute     ?fn (input string) string // 计算函数
}

pub struct Edge {
	from string
	to   string
}

pub struct ComputeGraph {
pub mut:
	nodes           map[string]ComputeNode
	edges           []Edge
	execution_order []string
}

pub struct ExecutionResult {
	node_id     string
	output      string
	error       string
	duration_ms int
}

// 创建新的计算图
pub fn new_graph() ComputeGraph {
	return ComputeGraph{
		nodes:           map[string]ComputeNode{}
		edges:           []
		execution_order: []
	}
}

// 添加节点到图
pub fn (mut graph ComputeGraph) add_node(node ComputeNode) ! {
	if node.id == '' {
		return error('节点 ID 不能为空')
	}
	if node.id in graph.nodes {
		return error('节点 "${node.id}" 已存在')
	}

	graph.nodes[node.id] = node
}

// 添加边（连接两个节点）
pub fn (mut graph ComputeGraph) add_edge(from string, to string) ! {
	if from !in graph.nodes {
		return error('源节点 "${from}" 不存在')
	}
	if to !in graph.nodes {
		return error('目标节点 "${to}" 不存在')
	}

	// 检查是否会形成循环
	if graph.would_create_cycle(from, to) {
		return error('添加边会形成循环')
	}

	graph.edges << Edge{
		from: from
		to:   to
	}
}

// 验证图的有效性
pub fn (graph ComputeGraph) validate() ! {
	// 检查循环
	if graph.has_cycle() {
		return error('图中存在循环')
	}

	// 检查所有节点都在边中被引用（除了起始节点）
	mut referenced := map[string]bool{}
	for edge in graph.edges {
		referenced[edge.to] = true
	}

	// 至少应该有一个起始节点（没有输入边）
	mut start_nodes := 0
	for node_id, _ in graph.nodes {
		if node_id !in referenced {
			start_nodes++
		}
	}

	if start_nodes == 0 && graph.nodes.len > 1 {
		return error('图没有起始节点（没有节点没有输入边）')
	}
}

// 生成执行顺序（拓扑排序）
pub fn (mut graph ComputeGraph) generate_execution_order() ! {
	graph.validate()!

	mut in_degree := map[string]int{}
	mut adj_list := map[string][]string{}

	// 初始化入度和邻接表
	for node_id, _ in graph.nodes {
		in_degree[node_id] = 0
		adj_list[node_id] = []
	}

	for edge in graph.edges {
		in_degree[edge.to]++
		adj_list[edge.from] << edge.to
	}

	// Kahn 算法进行拓扑排序
	mut queue := []string{}
	for node_id, degree in in_degree {
		if degree == 0 {
			queue << node_id
		}
	}

	mut order := []string{}
	for queue.len > 0 {
		node_id := queue.pop()
		order << node_id

		for next_node in adj_list[node_id] {
			in_degree[next_node]--
			if in_degree[next_node] == 0 {
				queue << next_node
			}
		}
	}

	if order.len != graph.nodes.len {
		return error('拓扑排序失败，图中可能存在循环')
	}

	graph.execution_order = order
}

// 执行计算图
pub fn (mut graph ComputeGraph) execute(input string) !string {
	graph.generate_execution_order()!

	mut current_input := input
	mut results := map[string]string{}

	for node_id in graph.execution_order {
		node := graph.nodes[node_id]

		// 执行节点计算
		if compute_fn := node.compute {
			current_input = compute_fn(current_input)
		}
		results[node_id] = current_input
	}

	return current_input
}

// 检查是否会形成循环
fn (graph ComputeGraph) would_create_cycle(from string, to string) bool {
	// 使用 DFS 检查是否能从 to 到达 from
	return graph.can_reach(to, from)
}

// 检查是否存在循环（DFS）
fn (graph ComputeGraph) has_cycle() bool {
	mut visited := map[string]bool{}
	mut rec_stack := map[string]bool{}

	for node_id, _ in graph.nodes {
		if !visited[node_id] {
			if graph.has_cycle_dfs(node_id, mut visited, mut rec_stack) {
				return true
			}
		}
	}

	return false
}

// DFS 检查循环的辅助函数
fn (graph ComputeGraph) has_cycle_dfs(node_id string, mut visited map[string]bool, mut rec_stack map[string]bool) bool {
	visited[node_id] = true
	rec_stack[node_id] = true

	// 找到所有相邻节点
	for edge in graph.edges {
		if edge.from == node_id {
			next_node := edge.to
			if !visited[next_node] {
				if graph.has_cycle_dfs(next_node, mut visited, mut rec_stack) {
					return true
				}
			} else if rec_stack[next_node] {
				return true
			}
		}
	}

	rec_stack[node_id] = false
	return false
}

// 检查是否能从源节点到达目标节点
fn (graph ComputeGraph) can_reach(from string, to string) bool {
	mut visited := map[string]bool{}
	return graph.can_reach_dfs(from, to, mut visited)
}

// DFS 检查可达性的辅助函数
fn (graph ComputeGraph) can_reach_dfs(node_id string, target string, mut visited map[string]bool) bool {
	if node_id == target {
		return true
	}

	visited[node_id] = true

	for edge in graph.edges {
		if edge.from == node_id {
			next_node := edge.to
			if !visited[next_node] {
				if graph.can_reach_dfs(next_node, target, mut visited) {
					return true
				}
			}
		}
	}

	return false
}

// 获取节点的入度
pub fn (graph ComputeGraph) get_in_degree(node_id string) int {
	mut count := 0
	for edge in graph.edges {
		if edge.to == node_id {
			count++
		}
	}
	return count
}

// 获取节点的出度
pub fn (graph ComputeGraph) get_out_degree(node_id string) int {
	mut count := 0
	for edge in graph.edges {
		if edge.from == node_id {
			count++
		}
	}
	return count
}

// 获取节点的前驱节点
pub fn (graph ComputeGraph) get_predecessors(node_id string) []string {
	mut preds := []string{}
	for edge in graph.edges {
		if edge.to == node_id {
			preds << edge.from
		}
	}
	return preds
}

// 获取节点的后继节点
pub fn (graph ComputeGraph) get_successors(node_id string) []string {
	mut succs := []string{}
	for edge in graph.edges {
		if edge.from == node_id {
			succs << edge.to
		}
	}
	return succs
}

// 获取图的统计信息
pub fn (graph ComputeGraph) get_stats() map[string]int {
	return {
		'node_count': graph.nodes.len
		'edge_count': graph.edges.len
	}
}

// 可视化图结构（Graphviz DOT 格式）
pub fn (graph ComputeGraph) to_dot() string {
	mut dot := 'digraph ComputeGraph {\n'

	for node_id, node in graph.nodes {
		dot += '  "${node_id}" [label="${node.name}"];\n'
	}

	for edge in graph.edges {
		dot += '  "${edge.from}" -> "${edge.to}";\n'
	}

	dot += '}\n'
	return dot
}
