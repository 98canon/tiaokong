## 启用要点

在哪里执行：不在 OpenCode 里改项目文件。外部工具在沙盒里单独跑，审过再拷回。

用哪些执行模型：用该外部工具自己的模型，写成 `<供应商>/<模型>`。同一供应商里价格相同的几档，选了哪一个写在方案里，这份示例不点名。派单写成 `<供应商>/<模型>#<档位>`。 能力档次、上下文、价格和来源看模型记录，不抄进方案。

档位表：

| 类型 | 执行 | 审查 |
|---|---|---|
| A 纯机械 | `<供应商>/<模型>#<低档>` | `<供应商>/<模型>#<低档>` |
| B 固定写代码 | `<供应商>/<模型>#<低档>` | `<供应商>/<模型>#<中档>` |
| C 常规实现 | `<供应商>/<模型>#<中档>` | `<供应商>/<模型>#<高档>` |
| D 较难 | `<供应商>/<模型>#<高档>` | `<供应商>/<模型>#<高档>` |
| E 高风险 | `<供应商>/<模型>#<高档>` | `<供应商>/<模型>#<高档>`，多路 |
| F 预调研和规划 | `<供应商>/<模型>#<高档>` | 无 |

结果不合格才升一档，顺序是 `<低档>`、`<中档>`、`<高档>`。最高档要用户同意。审查档位不低于同一行的执行档位。E 类多路审查。

额度用完或限流时：停下来告诉用户。不自动换工具，也不自动换模型。

## 沙盒步骤

工作目录取自本机配置里的工作目录根。跑下面的脚本之前，先设：

```powershell
$env:TIAOKONG_WORKROOT = '<工作目录根>\<项目标识>'
```

`<skill 目录>` 是本 skill 所在目录。

1. 建沙盒。不写 `-RulesName` 时，规则文件名是 `AGENTS.md`。Claude Code 要加 `-RulesName CLAUDE.md`。第一次在这个工作根上建沙盒时，脚本会建 `.tiaokong-workdir` 标记，其他脚本没有这个标记就不动手。

```powershell
& '<skill 目录>\scripts\new-sandbox.ps1' -Id <任务> -Project <项目目录> -Dirs @(<目录>...) -Files @(<文件>...) -RulesFile <项目规则文件> -RulesName <规则文件名>
```

2. 派单写到 `<工作目录根>\<项目标识>\dispatch\<任务>.md`。脚本把它复制成沙盒里的 `TASK.md`。`-ToolArgs` 里的 `{PROMPT}` 只换成一句提示，不放派单全文。`-Exe` 和 `-ToolArgs` 用下面的执行工具表。

```powershell
& '<skill 目录>\scripts\run-tool.ps1' -Id <任务> -Exe <可执行文件> -ToolArgs <见执行工具表>
```

续派同一任务时加 `-FollowUp '<一句提示>'`。要限时再加 `-TimeoutSec`，不写就用脚本的默认。参数里不要放双引号，长内容放进 TASK.md。

3. 核对。有适配目录的，先按该目录的 README.md 做它的核对，再跑通用核对。

```powershell
& '<skill 目录>\scripts\check-sandbox.ps1' -Id <任务>
```

4. 拷回。只拷 `-Allowed` 里的相对路径。

```powershell
& '<skill 目录>\scripts\copy-back.ps1' -Id <任务> -Project <项目目录> -Allowed @(<相对路径>...)
```

5. 清理。有适配目录的，先按该目录的 README.md 做它要求的清理，再跑通用清理。

```powershell
& '<skill 目录>\scripts\clean-sandbox.ps1' -ArchiveDir <日志归档目录>
```

要看过程时，另开一个窗口跑 `watch-runs.ps1`。`-LogDir` 指这个项目的 `logs`。有适配目录时，`-Formatter` 和 `-ProcessName` 按该目录的 README.md 填。

```powershell
& '<skill 目录>\scripts\watch-runs.ps1' -LogDir '<工作目录根>\<项目标识>\logs'
```

执行工具：

| 执行工具 | 可执行文件 | -ToolArgs | 规则文件名 | 适配目录 |
|---|---|---|---|---|
| agy | `$env:LOCALAPPDATA\agy\bin\agy.exe` | `@('-p','{PROMPT}')` | `AGENTS.md` | 有，`scripts\adapters\agy\`。`-p` 即 `--print`。模型、模式等其余参数见该目录的 README.md |
| Codex CLI | `codex` | `@('exec','--skip-git-repo-check','{PROMPT}')` | `AGENTS.md` | 无。参数已按 --help 核对，未实际跑过任务 |
| Claude Code | `claude` | `@('-p','{PROMPT}')` | `CLAUDE.md` | 无。参数已按 --help 核对，未实际跑过任务 |

Codex CLI 加了 `--skip-git-repo-check`，因为 `codex exec --help` 写明它允许在 git 仓库外运行，沙盒不带 `.git`。Claude Code 的 `-p` 即 `--print`，非交互跑完就退出。不要加 `--bare`，`claude --help` 写明它会跳过 `CLAUDE.md` 的自动发现。

- 每轮用完清空这个项目工作目录下的 `sandboxes`、`tmp`、`dispatch`、`logs`。`clean-sandbox.ps1` 清掉沙盒和临时目录，并把日志挪到 `-ArchiveDir`。`dispatch` 里的派单也要清掉。
- 测试只在沙盒里跑，拷回之前做完。
- 沙盒里不放真实密钥。`-Dirs` 和 `-Files` 不要带上密钥文件。
- 并发先用小任务实测再定上限，不在示例里写死数字。
