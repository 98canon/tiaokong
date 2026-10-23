# 调控师

OpenCode 的 skill：主会话担任总控，按指定方案把开发任务派给子代理，负责启用自检、规划、派单、选档位、并发、验证层级、多路审查、提交和汇报。

## 安装

仓库地址：<https://github.com/98canon/tiaokongshi>

```
git clone https://github.com/98canon/tiaokongshi.git
```

1. 把克隆下来的目录放到任意位置，再在 `~/.config/opencode/skills/` 下建一个名为 `调控师` 的目录联接指向它（Windows：`mklink /J`），或直接复制过去。仓库名是 `tiaokongshi`，联接名仍用 `调控师`。
2. 按 `templates/本机配置.example.md` 写一份 `~/.config/opencode/调控师-本机.md`。
3. 每个要用的项目，按 `templates/项目档案.md` 写一份项目档案（放在项目仓库以外），登记到本机配置里。

## 使用
在 OpenCode 里写 `@调控师 方案X`。不写就不启用。说「换成方案 Y」或「取消调控师」时切换或退出。

## 目录
- `SKILL.md`：主控规则。
- `references/`：四个执行方案。
- `规则/`：子代理通用守则、审查标准。不启用 skill 的项目也可以直接引用。
- `templates/`：派单骨架、项目档案、本机配置示例、agy 沙盒规则头。
- `scripts/`：方案一（agy）用的 PowerShell 脚本，存成带 BOM 的 UTF-8。
- `依据/`：用户的原始规则原文，改规则时以它为准。
- `待合入.md`：使用中总结的教训和待验证项，用户同意后才改进规则本体。

## 改动规则
规则本体在运行中不修改。改动先记进 `待合入.md`，用户同意后再改，升 `VERSION`，写 `CHANGELOG.md`，提交。
