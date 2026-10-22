# 方案二：Opus 5.5 主控，dog-claude 的 Opus 5.5 做子代理（月末三折时用）

和 `主控公共规则.md` 一起使用。子代理是 OpenCode 内置模型，直接在本地项目里执行：不建沙盒，不需要监控。

## 模型和档位

- 子代理只用 `dog-claude/claude-opus-5-5`。Sonnet 5.5 和它同价，不使用。
- 档位从低到高：low / medium / high / xhigh / max。
- 派法：subagent 工具的 model 参数写 `dog-claude/claude-opus-5-5#<档位>`。改文件用 general 子代理，只读调研用 explore 子代理。

| 类型 | 起步 |
|---|---|
| A 纯机械 | low |
| B 固定写代码 | low |
| C 常规实现 | low |
| D 较难 | medium |
| E 高风险 | medium，主控细审 |
| F 预调研和规划 | medium |

升档顺序：low → medium → high → xhigh → max。max 只在用户同意后使用。

## 执行注意

- 子代理直接改项目文件，所以并发时各批改的文件必须互不重叠。
- 子代理的进度在 OpenCode 的子会话里能直接看到，不另写监控。
- 遇到 429 或额度不足，降低并发；仍然不行就停下来告诉用户。
