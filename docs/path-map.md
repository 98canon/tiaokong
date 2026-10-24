# 路径对照（2.3.0 起）

2.3.0 把仓库里的文件、本机运行目录和 skill 名字改成英文。文件内容仍用中文。项目仓库里生成的 `阶段表.md` 不改名。

这份只是改名记录。2.3.0 不提供迁移，也不读旧路径：旧数据由用户清掉，各项目重新绑定。

## skill

| 旧 | 新 |
|---|---|
| 名字 `调控师`，调用写 `@调控师` | 名字 `tiaokong`，调用写 `@tiaokong` |
| `~/.config/opencode/skills/调控师/` | `~/.config/opencode/skills/tiaokong/` |
| GitHub 仓库 `tiaokongshi` | `tiaokong` |

## 仓库

| 旧 | 新 |
|---|---|
| `规则/子代理通用守则.md` | `rules/subagent-rules.md` |
| `规则/审查标准.md` | `rules/review-standard.md` |
| `templates/派单.md` | `templates/dispatch.md` |
| `templates/项目档案.md` | `templates/project-profile.md` |
| `templates/登记.md` | `templates/registration.md` |
| `templates/本机配置.example.md` | `templates/local-config.example.md` |
| `templates/模型记录.md` | `templates/model-record.md` |
| `templates/阶段表.md` | `templates/stage-table.md` |
| `templates/沙盒规则.md` | `templates/sandbox-rules.md` |
| `references/预置方案/说明.md` | `references/presets/README.md` |
| `references/预置方案/示例-省钱.md` | `references/presets/example-saving.md` |
| `references/预置方案/示例-高效.md` | `references/presets/example-fast.md` |
| `references/预置方案/示例-均衡.md` | `references/presets/example-balanced.md` |
| `references/预置方案/示例-沙盒.md` | `references/presets/example-sandbox.md` |
| `scripts/adapters/agy/说明.md` | `scripts/adapters/agy/README.md` |
| `依据/代码审查任务.md` | `docs/basis/code-review-task.md` |
| `依据/多代理开发通用提速方案.md` | `docs/basis/multi-agent-speedup.md` |
| `依据/自主推进与测试范围（用户指令）.md` | `docs/basis/autonomy-and-test-scope.md` |
| `待合入.md` | 删除（教训写进各项目自己的 `pending-merge.md`） |
| `_archive/优化方案/` | `docs/archive/plans/`（不入库） |
| `SKILL.md` 里不常用的步骤 | `steps/`：`new-binding.md`、`lock-conflict.md`、`full-research.md`、`model-failure.md` |

## 本机（`~/.config/opencode/`）

| 旧 | 新 |
|---|---|
| `调控师-本机.md`、`调控师-本机.lock` | `tiaokong-local.md`、`tiaokong-local.lock` |
| `调控师-模型记录.md`、`调控师-模型记录.lock` | `tiaokong-model-record.md`、`tiaokong-model-record.lock` |
| `调控师-登记/` | `tiaokong-registry/` |
| `调控师-项目/<项目标识>/` | `tiaokong-projects/<项目标识>/` |
| `调控师-方案/`（2.0 以前） | 去掉 |
| 工作目录根的默认名 `调控师-work` | `tiaokong-work` |

## 项目目录（`tiaokong-projects/<项目标识>/`）

| 旧 | 新 |
|---|---|
| `项目档案.md` | `project-profile.md` |
| `方案/` | `plans/` |
| `记录/` | `records/` |
| `待合入.md` | `pending-merge.md` |
| `写入权.lock` | `write.lock` |
| 新方案的文件名 `均衡方案.md`、`均衡方案2.md` | `balanced.md`、`balanced-2.md`（省钱 `saving`、高效 `fast`、沙盒 `sandbox`） |

## 项目标识

以前由用户起名，可以用中文。2.3.0 起按工作目录自动算：`<文件夹名里的英文和数字>-<登记名前 6 位>`，算不出英文部分就用 `p`。例如 `os-xxxxxx`、`p-xxxxxx`。算法见 `SKILL.md`「绑定」。
