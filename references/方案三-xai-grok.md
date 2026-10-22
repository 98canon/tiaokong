# 方案三：xAI 的 Grok 4.7 做子代理（Grok 订阅）

子代理是 OpenCode 内置模型，直接在本地项目里执行：不建沙盒，不需要监控。

## 模型和档位

- 子代理：`xai/grok-4.7`。
- 档位从低到高：low / medium / high / xhigh。
- 写法：`xai/grok-4.7#<档位>`。
- 自检时派一个很小的只读任务，确认 `xai` 可用、走的是用户的订阅。

| 类型 | 执行起步 | 审查起步 |
|---|---|---|
| A 纯机械 | low | low |
| B 固定写代码 | low | low |
| C 常规实现 | low | medium |
| D 较难 | medium | high |
| E 高风险 | high | high，多路 |
| F 预调研和规划 | medium | — |

升档顺序：low → medium → high → xhigh。xhigh 只在用户同意后使用。

## 执行注意

- 子代理直接改项目文件，并发时各批改的文件必须互不重叠。
- 进度在 OpenCode 的子会话里能直接看到，不另写监控。
- 订阅额度用完（429、quota 等提示）：停止派单，告诉用户，等用户决定换方案还是等待重置。
