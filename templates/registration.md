# 调控师登记

（放在 `~/.config/opencode/tiaokong-registry/<登记名>.md`。一个项目一个。不写进度，不写方案，不写别的项目。写入方法见 `steps/new-binding.md`，一次写完，不先建空文件。）

## 登记名

登记名由工作目录算出，找文件时不列目录：

1. 取会话的工作目录（OpenCode 显示的那一个），去掉末尾的 `\` 或 `/`，把 `\` 改成 `/`。Windows 上整串转小写。
2. 对这段文字的 UTF-8 字节做 SHA256，小写十六进制就是登记名。

Windows 用这条命令算，不自己改写：

```powershell
$p = '<工作目录>'.TrimEnd('\','/').Replace('\','/').ToLowerInvariant()
[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($p))).Replace('-','').ToLowerInvariant()
```

路径里有 `'` 时，先写成两个 `''` 再放进单引号，例如 `F:\O''Brien`。

## 正文

- 项目目录（规范化后）：
- 项目标识（按 `steps/new-binding.md` 自动算出）：
- 项目档案路径：
