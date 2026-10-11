# cocoapods-podx MCP

第二版 MCP 暴露查询与常用维护命令，方便 Codex 管理当前工程的 podx / mgit 状态。

## 支持工具

- `podx_doctor`：执行 `podx doctor`
- `podx_main`：执行 `podx main`
- `mgit_status`：执行 `mgit status`
- `mgit_branch`：执行 `mgit branch`
- `mgit_diff`：执行 `mgit diff`
- `podx_install`：执行 `podx install`
- `podx_update`：执行 `podx update`
- `mgit_pull`：执行 `mgit pull`
- `mgit_checkout`：执行 `mgit checkout <branch>`
- `mgit_stash`：执行 `mgit stash`

## 启动

不需要安装 npm 依赖，直接使用本机 Node.js：

```bash
node /path/to/mpod/cocoapods-podx-mcp/server.js
```

## Codex 配置示例

```json
{
  "mcpServers": {
    "cocoapods-podx": {
      "command": "node",
      "args": [
        "/path/to/mpod/cocoapods-podx-mcp/server.js"
      ],
      "cwd": "/path/to/ios-app"
    }
  }
}
```

## 参数

每个工具都支持：

- `projectDirectory`：可选，指定包含 `Podfile` 的工程目录。
- `productLine`：可选，指定产品线 ID，例如 `app`、`media`；等同命令行 `--line`。

`mgit_status`、`mgit_branch`、`mgit_diff`、`mgit_pull`、`mgit_checkout`、`mgit_stash` 额外支持：

- `repos`：可选，指定仓库名列表，例如 `["AppFeatureKit", "AppLibrary"]`。

`mgit_checkout` 额外支持：

- `branch`：必填，指定切换到的分支。

`mgit_diff` 额外支持：

- `maxOutput`：可选，限制输出字符数，默认 `60000`。

`podx_install`、`podx_update` 额外支持：

- `repoUpdate`：可选，等同于追加 `--repo-update`。

`podx_update` 额外支持：

- `pods`：可选，指定更新的 pod 名列表，例如 `["AppLibrary"]`。

多产品线工程可以这样调用：

```json
{
  "projectDirectory": "/path/to/ios-app",
  "productLine": "media"
}
```
