# 调控师（tiaokong）

OpenCode 的 skill：主会话担任总控，按指定方案把开发任务派给子代理，负责启用自检、规划、派单、选档位、并发、验证层级、多路审查、提交和汇报。

## 安装

仓库地址：<https://github.com/98canon/tiaokong>

```
git clone https://github.com/98canon/tiaokong.git "$HOME/.config/opencode/skills/tiaokong"
```

1. 克隆到 `~/.config/opencode/skills/tiaokong`，或克隆到任意位置后在那里建一个名为 `tiaokong` 的目录联接（Windows：`mklink /J`）。OpenCode 要求 skill 的目录名和 `SKILL.md` 里的 `name` 一致，只能用小写英文、数字和 `-`。
2. 按 `templates/local-config.example.md` 写一份 `~/.config/opencode/tiaokong-local.md`。本机配置只写机器事实，以及你认可的「可信来源」。模型核验和每个模型的表现记在全机共用的 `~/.config/opencode/tiaokong-model-record.md`（格式见 `templates/model-record.md`），由调控师在调研和每批审查后写，不用手填。
3. 每个项目第一次 `@tiaokong` 时会做绑定，按 `templates/registration.md` 新建登记文件。项目标识按项目目录自动算出。项目档案按 `templates/project-profile.md` 写，放在项目仓库以外，可以沿用原位置。

2.3.0 起不兼容以前的中文路径和旧数据。以前用过的，清掉旧数据后在各项目里重新绑定。改名对照在 `docs/path-map.md`。

## 开发和安装分开

开发和维护在 `<开发克隆>` 里做（改规则、审查、`docs/` 都在这里）。改完提交推送，这时还不生效。`~/.config/opencode/skills/tiaokong` 放另一份只用来拉取的克隆 `<安装克隆>`。发布时执行 `git -C <安装克隆> pull --ff-only`。`<安装克隆>` 不要直接改。自检的「版本」一项会看它的 `git status`。

在 `<开发克隆>` 根目录建一个空文件 `.tiaokong-dev`（不入库）：`New-Item -ItemType File .tiaokong-dev`。有这个标记，调控师加载时会认出这是开发仓库，警告并停下，不会被当作 skill 使用。`AGENTS.md` 写了在开发仓库里打开会话时的规矩。

## 使用

在 OpenCode 里写 `@tiaokong`。进入时先绑定当前项目。

- 还没有方案：完整调研、制定方案、启用自检、按批开发。制定方案时先选方向：省钱、高效、均衡、沙盒，默认推荐做得到的均衡。价格相同但能力不同的模型，由你选用哪一个。四个方向都做不到时，会如实说明，并问你是否只用 `rules/` 下的两份文件；都不用就结束，不改任何东西。
- 方案文件按方向的英文名保存，例如 `balanced.md`；同一个方向的第二份叫 `balanced-2.md`，也可以自己起名。
- 已有方案并写了名字，例如 `@tiaokong balanced`：先做紧要调研。没有冲突就按这份方案继续；有冲突就停下来，等你选。
- 已有方案但没写名字：停下来问，推荐档案里的「当前方案」，没有才推荐第一份。

探测只对准方案里实际执行任务的模型，同一次启用里每个模型只探测一次。说「换成方案 Y」或「取消调控师」时切换或退出。

## 目录

- `SKILL.md`：主控规则，启用时读。
- `steps/`：不常用的步骤（新建绑定、标记冲突、完整调研和制定方案、子代理不合格），到了那一步才读。
- `rules/`：子代理通用守则、审查标准。不启用 skill 的项目也可以直接引用。
- `templates/`：派单骨架、项目档案、登记、模型记录、阶段表、本机配置示例、沙盒规则头。
- `references/presets/`：占位符示例。运行时不读，不占上下文。
- `scripts/`：沙盒类方案用的通用 PowerShell 脚本：`new-sandbox.ps1`、`run-tool.ps1`（内部调用 `run-tool-inner.ps1`）、`check-sandbox.ps1`、`watch-runs.ps1`、`clean-sandbox.ps1`、`copy-back.ps1`。`adapters/agy/` 是 agy 的适配。这些脚本存成带 BOM 的 UTF-8。只有当前方案写明要用时才调用。
- `docs/`：只用于维护 skill 本体，运行时不读。见 `docs/maintenance.md`。
- 方案在各项目自己的 `~/.config/opencode/tiaokong-projects/<项目标识>/plans/`，项目之间不互读。一份文件一个方案。

## 改动规则

运行时以 `SKILL.md` 和 `steps/` 为准。教训默认写进项目自己的待合入，默认路径是 `~/.config/opencode/tiaokong-projects/<项目标识>/pending-merge.md`。只对这个项目成立的，用户同意后合进项目规则。所有项目都要遵守的，在 skill 仓库另开维护会话（不启用调控师）改规则，升 `VERSION`，写 `CHANGELOG.md`，用户同意后提交。还原规则用 git。针对调控师本身的优化方案写在 `docs/plans/`，审查确认、合入之后移进 `docs/archive/plans/`。项目的执行方案不放这里。改方案之前先备份：路径写在这个项目的档案里，磁盘由用户指定，只含这个项目的方案，不含 `.git`。一键还原只恢复方案。

## 许可

[知识共享 署名-非商业性使用 4.0 国际](https://creativecommons.org/licenses/by-nc/4.0/deed.zh-Hans)（CC BY-NC 4.0）。协议全文在 `LICENSE`。

- 可以复制，也可以在此基础上修改和使用。
- 不可以用于商业目的。
- 再发布时保留署名，并标明是否修改过。
