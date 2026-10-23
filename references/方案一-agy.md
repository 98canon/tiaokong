# 方案一：Antigravity CLI（agy）做子代理

agy 不在 OpenCode 里跑，所以本方案要建 G 盘沙盒、审过再拷回，并给用户监控命令。脚本在本 skill 的 `scripts/` 下（下文写作 `<scripts>`）。工作目录见本机配置（下文写作 `<工作目录>`），下有 `sandboxes`、`tmp`、`dispatch`、`logs`，每轮用完清空。脚本从环境变量 `TIAOKONG_WORKROOT` 取这个路径，没设就停下来问。下文出现的 `G:\agy-work` 都是举例，实际指 `<工作目录>`。

## 一、模型和档位

| 模型 ID | 档位 | 用途 |
|---|---|---|
| `gemini-3.8-flash-low` / `-medium` / `-high` | 写在模型名里 | 主力，绝大多数任务 |
| `claude-opus-4-6-thinking` | 可加 `--effort low/medium/high/xhigh/max`（是否生效待验证） | 少数关键的预调研或高风险任务，一次最多一两个，不并发 |
| `claude-sonnet-4-6` | 同上 | Opus 4.6 额度用完时的备用。自检时确认它和 Opus 是否共用额度；共用就不当备用 |
| `gpt-oss-120b-medium` | 只有 medium | 可用但不启用 |

| 类型 | 执行起步 | 审查起步 |
|---|---|---|
| A 纯机械 | flash-low | flash-low |
| B 固定写代码 | flash-low | flash-medium |
| C 常规实现 | flash-medium | flash-high |
| D 较难 | flash-high | flash-high，必要时 Opus 4.6 |
| E 高风险 | flash-high，必要时 Opus 4.6（不并发） | Opus 4.6 或 Sonnet 4.6，多路时其余用 flash-high |
| F 预调研和规划 | Opus 4.6 或 Sonnet 4.6（一两个）；额度不够时 flash-high | — |

升档顺序：flash-low → flash-medium → flash-high → Opus 4.6。`--effort` 用 xhigh 以上要用户同意。

额度：
- Claude 模型的个人额度很小：实测并发 8 个长任务几十秒内就触发 429「Individual quota reached」，约 5 小时后重置。
- 结果 `status` 为 ERROR 或日志出现 `RESOURCE_EXHAUSTED`：Claude 模型换回 Flash 重派；Flash 也用完时停下来告诉用户。
- 并发：Flash 实测 8 个可以；Claude 模型一次最多一两个。换了环境时先用简单任务实测（例如让多个实例各画一张「鹈鹕骑自行车」SVG）再定上限。

## 二、自检时额外检查

- `& "$env:LOCALAPPDATA\agy\bin\agy.exe" models` 能列出模型（已登录）。没登录时请用户在浏览器里登录，不要绕过。
- 权限配置实际从哪个文件读：启动日志 `~/.gemini/antigravity-cli/log/cli-*.log` 里搜 `stored shared config permissions`。实测读的是 `~/.gemini/config/config.json` 的 `userSettings.globalPermissionGrants`。
- 项目档案里列的 agy 允许命令，是否都已在 allow 里。
- `config.json` 里的 `nonWorkspaceFileAccessPolicy`：是 ALLOW 时，agy 能读工作区以外的文件，要在自检报告里提示，并建议加 `read_file` 的 deny 规则保护密钥文件。
- `G:\agy-work\sandboxes`、`tmp`、`logs` 是空的（上一轮已清理）。

## 三、一批的流程

1. 建沙盒：
   ```powershell
   & '<scripts>\new-sandbox.ps1' -Id <任务> -Project <项目目录> -Dirs <目录...> -Files <文件...> -RulesFile <项目规则文件>
   ```
   `AGENTS.md` 会自动由 `templates/agy-AGENTS.md`、`规则/子代理通用守则.md`、项目规则文件三段拼成，派单里不用再让它读这几份。审查派单另附 `规则/审查标准.md` 和项目审查补充（复制进 `_ctx\`）。批次材料（预调研、决定、方案摘录）复制进沙盒的 `_ctx\`，并同步复制进 `<任务>.orig\_ctx\`，免得核对时被当成改动。
2. 写派单到 `G:\agy-work\dispatch\<任务>.md`（按 `templates/派单.md`，报告写沙盒根目录的 REPORT.md）。
3. 派出（后台运行，等完成通知，不轮询）：
   ```powershell
   & '<scripts>\run-agy.ps1' -Id <任务> -Model <模型ID> [-Effort <档位>] -TimeoutSec 3600
   ```
   续派同一会话：加 `-Conversation <id>`，或 `-FollowUp '<一句英文>'`。
4. 核对：`& '<scripts>\check-run.ps1' -Id <任务>`，看结果、被拒操作、沙盒外的访问、改动文件。再按 SKILL.md 第十三节做机械核对，按第五节派审查（审查也在沙盒里跑，只读）。
5. 拷回：`& '<scripts>\copy-back.ps1' -Id <任务> -Project <项目目录> -Allowed <相对路径...>`。项目里的文件在建沙盒后被改过就会拒绝。拷回后在项目里跑对应层级的测试，通过后提交。
6. 一轮全部结束：先把各沙盒的 REPORT.md 另存到项目档案指定的位置，再运行 `& '<scripts>\clean-agy.ps1' -ArchiveDir <项目档案里的日志归档目录>`。

## 四、派单和权限的注意事项

- 派单原文不传给 `-p`：PowerShell 5.1 会把参数里的双引号拆错，中文长文本也容易乱码。脚本已经处理（派单复制成 TASK.md）。
- 结果 `status` 为 SUCCESS 不代表完成。命令被拒后 `response` 常是空的，要看 `denied_actions`。
- 禁止 `--dangerously-skip-permissions`。无界面模式下，没放行的命令一律被拒，而且一被拒这一轮就结束；用 `-FollowUp` 续派，说明哪条命令被拒、让它重读规则、从中断处继续。
- 经用户同意后，可以只放行检查类命令：先备份配置；往 allow 里追加，不删原有条目；写成 `command(regex:...)`（整行匹配）；参数部分排除 `;&|<>`$`；解释器写完整路径；放行后做一次金丝雀测试。
- 放行测试命令等于允许执行 agy 可以改的测试代码，所以测试只能在沙盒里跑，沙盒里不能有真实密钥和真实数据。
- 写中文的 PowerShell 脚本要存成带 BOM 的 UTF-8。

## 五、给用户的监控命令

在派出第一批时告诉用户，在自己的 PowerShell 里运行：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.config\opencode\skills\调控师\scripts\watch-agy.ps1"
```
它持续跟随 `G:\agy-work\logs` 下的日志，每个动作一行：时间、任务、读文件（灰）、改文件（紫）、跑命令（黄）、出错（红）、结果（绿，含耗时、用量和被拒操作）；窗口标题显示正在运行的 agy 数量。

## 六、清理的边界

`clean-agy.ps1` 只删本轮日志里记下的 conversation_id 对应的文件、本轮任务启动前后 5 秒内新建的 agy 日志，以及沙盒和临时目录。不动：用户自己的会话和 agy 进程、共享数据、MCP 缓存、配置文件（主控改过的权限按用户意见保留或还原）、agy 程序本身。时间段内有用户自己的 agy 会话在跑时，先确认再清理。文件被占用删不掉时，告诉用户手动删除的命令。
