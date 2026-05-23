#!/usr/bin/env node

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SERVER_NAME = "cocoapods-podx-mcp";
const SERVER_VERSION = "0.2.0";
const DEFAULT_TIMEOUT_MS = 120000;
const DEFAULT_MAX_OUTPUT = 60000;

const __dirname = dirname(fileURLToPath(import.meta.url));
const fallbackProjectDirectory = resolve(__dirname, "../..");

const tools = [
  {
    name: "podx_doctor",
    description: "检查当前 Podfile 工程的 podx 本地组件状态。",
    inputSchema: projectSchema()
  },
  {
    name: "podx_main",
    description: "查看当前 Podfile 中内部组件的远端依赖配置。",
    inputSchema: projectSchema()
  },
  {
    name: "mgit_status",
    description: "查看主工程与本地组件仓库的 git status。",
    inputSchema: reposSchema()
  },
  {
    name: "mgit_branch",
    description: "查看主工程与本地组件仓库的当前分支。",
    inputSchema: reposSchema()
  },
  {
    name: "mgit_diff",
    description: "查看主工程与本地组件仓库的 git diff。",
    inputSchema: reposSchema({
      maxOutput: {
        type: "number",
        description: "最大输出字符数，默认 60000。"
      }
    })
  },
  {
    name: "podx_install",
    description: "执行 podx install，按 Podfile / Podfile.overlay 安装依赖。",
    inputSchema: podCommandSchema()
  },
  {
    name: "podx_update",
    description: "执行 podx update，可指定组件；组件在 Podfile.overlay 中时会按本地组件更新语义处理。",
    inputSchema: podCommandSchema({
      pods: {
        type: "array",
        description: "可选 pod 名列表，例如 NNBussCom、RxSwift。",
        items: { type: "string" }
      }
    })
  },
  {
    name: "mgit_pull",
    description: "对主工程与本地组件仓库执行 mgit pull。",
    inputSchema: reposSchema()
  },
  {
    name: "mgit_checkout",
    description: "对主工程与本地组件仓库执行 mgit checkout <branch>。",
    inputSchema: reposSchema({
      branch: {
        type: "string",
        description: "目标分支名，例如 develop 或 release/5.14.2。"
      }
    }, ["branch"])
  },
  {
    name: "mgit_stash",
    description: "对主工程与本地组件仓库执行 mgit stash。",
    inputSchema: reposSchema()
  }
];

let input = Buffer.alloc(0);
let transportMode = null;

process.stdin.on("data", chunk => {
  input = Buffer.concat([input, chunk]);
  readMessages();
});

process.stdin.on("end", () => {
  process.exit(0);
});

function projectSchema(extraProperties = {}, required = []) {
  return {
    type: "object",
    properties: {
      projectDirectory: {
        type: "string",
        description: "Podfile 工程目录，默认使用当前目录向上查找。"
      },
      ...extraProperties
    },
    required,
    additionalProperties: false
  };
}

function podCommandSchema(extraProperties = {}) {
  return projectSchema({
    repoUpdate: {
      type: "boolean",
      description: "是否追加 --repo-update。"
    },
    maxOutput: {
      type: "number",
      description: "最大输出字符数，默认 60000。"
    },
    ...extraProperties
  });
}

function reposSchema(extraProperties = {}, required = []) {
  return projectSchema({
    repos: {
      type: "array",
      description: "可选仓库名列表，例如 NNBussCom、NNLibrary。",
      items: { type: "string" }
    },
    ...extraProperties
  }, required);
}

function readMessages() {
  while (true) {
    const headerEnd = input.indexOf("\r\n\r\n");
    if (headerEnd === -1) {
      if (!readLineDelimitedMessage()) return;
      continue;
    }

    const header = input.slice(0, headerEnd).toString("utf8");
    const contentLength = parseContentLength(header);
    if (contentLength == null) {
      input = input.slice(headerEnd + 4);
      continue;
    }

    const messageStart = headerEnd + 4;
    const messageEnd = messageStart + contentLength;
    if (input.length < messageEnd) return;

    const rawMessage = input.slice(messageStart, messageEnd).toString("utf8");
    input = input.slice(messageEnd);
    transportMode ??= "content-length";

    try {
      handleMessage(JSON.parse(rawMessage));
    } catch (error) {
      sendError(null, -32700, `JSON 解析失败：${error.message}`);
    }
  }
}

function readLineDelimitedMessage() {
  const newline = input.indexOf("\n");
  if (newline === -1) return false;

  const rawMessage = input.slice(0, newline).toString("utf8").trim();
  input = input.slice(newline + 1);
  if (!rawMessage) return true;

  transportMode ??= "line";
  try {
    handleMessage(JSON.parse(rawMessage));
  } catch (error) {
    sendError(null, -32700, `JSON 解析失败：${error.message}`);
  }
  return true;
}

function parseContentLength(header) {
  for (const line of header.split("\r\n")) {
    const match = /^Content-Length:\s*(\d+)$/i.exec(line);
    if (match) return Number(match[1]);
  }
  return null;
}

async function handleMessage(message) {
  if (message.method?.startsWith("notifications/")) return;

  try {
    if (message.method === "initialize") {
      sendResult(message.id, {
        protocolVersion: message.params?.protocolVersion ?? "2024-11-05",
        capabilities: {
          tools: {}
        },
        serverInfo: {
          name: SERVER_NAME,
          version: SERVER_VERSION
        }
      });
      return;
    }

    if (message.method === "ping") {
      sendResult(message.id, {});
      return;
    }

    if (message.method === "tools/list") {
      sendResult(message.id, { tools });
      return;
    }

    if (message.method === "resources/list") {
      sendResult(message.id, { resources: [] });
      return;
    }

    if (message.method === "prompts/list") {
      sendResult(message.id, { prompts: [] });
      return;
    }

    if (message.method === "tools/call") {
      const result = await callTool(message.params?.name, message.params?.arguments ?? {});
      sendResult(message.id, result);
      return;
    }

    sendError(message.id, -32601, `不支持的方法：${message.method}`);
  } catch (error) {
    sendError(message.id, -32000, error.message);
  }
}

async function callTool(name, args) {
  const projectDirectory = findProjectDirectory(args.projectDirectory);
  if (!projectDirectory) {
    return toolError("必须在包含 Podfile 的工程目录下执行，或传入 projectDirectory。");
  }

  const repos = Array.isArray(args.repos) ? args.repos.filter(Boolean) : [];
  const pods = Array.isArray(args.pods) ? args.pods.filter(Boolean) : [];
  const maxOutput = Number(args.maxOutput) > 0 ? Number(args.maxOutput) : DEFAULT_MAX_OUTPUT;
  const repoUpdate = args.repoUpdate === true ? ["--repo-update"] : [];

  switch (name) {
    case "podx_doctor":
      return commandTool(projectDirectory, "podx", ["doctor"], maxOutput);
    case "podx_main":
      return commandTool(projectDirectory, "podx", ["main"], maxOutput);
    case "mgit_status":
      return commandTool(projectDirectory, "mgit", ["status", ...repos], maxOutput);
    case "mgit_branch":
      return commandTool(projectDirectory, "mgit", ["branch", ...repos], maxOutput);
    case "mgit_diff":
      return commandTool(projectDirectory, "mgit", ["diff", ...repos], maxOutput);
    case "podx_install":
      return commandTool(projectDirectory, "podx", ["install", ...repoUpdate], maxOutput);
    case "podx_update":
      return commandTool(projectDirectory, "podx", ["update", ...pods, ...repoUpdate], maxOutput);
    case "mgit_pull":
      return commandTool(projectDirectory, "mgit", ["pull", ...repos], maxOutput);
    case "mgit_checkout":
      if (!args.branch) return toolError("mgit_checkout 需要传入 branch。");
      return commandTool(projectDirectory, "mgit", ["checkout", ...repos, args.branch], maxOutput);
    case "mgit_stash":
      return commandTool(projectDirectory, "mgit", ["stash", ...repos], maxOutput);
    default:
      return toolError(`未知工具：${name}`);
  }
}

function findProjectDirectory(projectDirectory) {
  const start = projectDirectory ? resolve(projectDirectory) : process.cwd();
  const found = nearestPodfileDirectory(start);
  if (found) return found;
  return nearestPodfileDirectory(fallbackProjectDirectory);
}

function nearestPodfileDirectory(start) {
  let current = resolve(start);
  while (true) {
    if (existsSync(resolve(current, "Podfile"))) return current;
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

async function commandTool(cwd, command, args, maxOutput) {
  const result = await runCommand(cwd, command, args, maxOutput);
  const text = [
    `$ ${command} ${args.join(" ")}`,
    `cwd: ${cwd}`,
    "",
    result.output
  ].join("\n").trimEnd();

  return {
    isError: result.exitCode !== 0,
    content: [
      {
        type: "text",
        text: result.truncated ? `${text}\n\n... output truncated ...` : text
      }
    ]
  };
}

function runCommand(cwd, command, args, maxOutput) {
  return new Promise(resolveCommand => {
    const child = spawn(command, args, {
      cwd,
      env: {
        ...process.env,
        PATH: [
          "/opt/homebrew/bin",
          "/usr/local/bin",
          "/usr/bin",
          "/bin",
          "/usr/sbin",
          "/sbin",
          process.env.PATH ?? ""
        ].join(":")
      },
      stdio: ["ignore", "pipe", "pipe"]
    });

    let output = "";
    let truncated = false;
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      appendOutput(`\n[timeout] command exceeded ${DEFAULT_TIMEOUT_MS}ms\n`);
    }, DEFAULT_TIMEOUT_MS);

    const appendOutput = chunk => {
      if (output.length >= maxOutput) {
        truncated = true;
        return;
      }
      output += chunk;
      if (output.length > maxOutput) {
        output = output.slice(0, maxOutput);
        truncated = true;
      }
    };

    child.stdout.on("data", chunk => appendOutput(chunk.toString("utf8")));
    child.stderr.on("data", chunk => appendOutput(chunk.toString("utf8")));
    child.on("error", error => {
      clearTimeout(timer);
      resolveCommand({
        exitCode: 127,
        output: `命令执行失败：${error.message}`,
        truncated
      });
    });
    child.on("close", exitCode => {
      clearTimeout(timer);
      resolveCommand({
        exitCode: exitCode ?? 1,
        output: output.trimEnd(),
        truncated
      });
    });
  });
}

function toolError(message) {
  return {
    isError: true,
    content: [
      {
        type: "text",
        text: message
      }
    ]
  };
}

function sendResult(id, result) {
  sendMessage({
    jsonrpc: "2.0",
    id,
    result
  });
}

function sendError(id, code, message) {
  sendMessage({
    jsonrpc: "2.0",
    id,
    error: {
      code,
      message
    }
  });
}

function sendMessage(message) {
  const payload = JSON.stringify(message);
  if (transportMode === "line") {
    process.stdout.write(`${payload}\n`);
    return;
  }
  process.stdout.write(`Content-Length: ${Buffer.byteLength(payload, "utf8")}\r\n\r\n${payload}`);
}
