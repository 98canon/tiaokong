# 方案四：dog 供应商的 Grok 4.7 做子代理（日常）

子代理是 OpenCode 内置模型，直接在本地项目里执行：不建沙盒，不需要监控。

## 模型和档位

- 子代理：`gog/grok-4.7`（供应商 ID 是 gog，显示名是 dog）。
- 档位从低到高：none / minimal / low / medium / high / xhigh。
- 写法：`gog/grok-4.7#<档位>`。

| 类型 | 执行起步 | 审查起步 |
|---|---|---|
| A 纯机械 | none | minimal |
| B 固定写代码 | minimal | low |
| C 常规实现 | low | medium |
| D 较难 | medium | high |
| E 高风险 | high | high，多路 |
| F 预调研和规划 | medium | — |

升档顺序：none → minimal → low → medium → high → xhigh。xhigh 只在用户同意后使用。

none 和 minimal 只用于派单已经写到「照着做」程度的任务：文件、函数、改法和断言都写明了。派单写得不够细时，从 low 起步。

## 执行注意

- 子代理直接改项目文件，并发时各批改的文件必须互不重叠。
- 进度在 OpenCode 的子会话里能直接看到，不另写监控。
- 遇到 429 或额度不足，降低并发；仍然不行就停下来告诉用户。
