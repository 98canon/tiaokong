# 方案四：Opus 5.5 主控，dog 供应商的 Grok 4.7 做子代理（日常）

和 `主控公共规则.md` 一起使用。子代理是 OpenCode 内置模型，直接在本地项目里执行：不建沙盒，不需要监控。

## 模型和档位

- 子代理：`gog/grok-4.7`（供应商 ID 是 gog，显示名是 dog）。
- 档位从低到高：none / minimal / low / medium / high / xhigh。
- 派法：subagent 工具的 model 参数写 `gog/grok-4.7#<档位>`。改文件用 general 子代理，只读调研用 explore 子代理。

| 类型 | 起步 |
|---|---|
| A 纯机械 | none |
| B 固定写代码 | minimal |
| C 常规实现 | low |
| D 较难 | medium |
| E 高风险 | high，主控细审 |
| F 预调研和规划 | medium |

升档顺序：none → minimal → low → medium → high → xhigh。xhigh 只在用户同意后使用。

none 和 minimal 只用于派单已经写到「照着做」程度的任务：文件、函数、改法和断言都写明了。派单写得不够细时，从 low 起步。

## 执行注意

- 子代理直接改项目文件，所以并发时各批改的文件必须互不重叠。
- 子代理的进度在 OpenCode 的子会话里能直接看到，不另写监控。
- 遇到 429 或额度不足，降低并发；仍然不行就停下来告诉用户。
