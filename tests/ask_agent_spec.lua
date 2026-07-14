local ask_agent = require("ask-agent")

describe("ask-agent", function()
  before_each(function()
    ask_agent.setup({
      notify = function() end,
    })
  end)

  it("builds codex exec args", function()
    local args = ask_agent.build_args("/tmp/repo")

    assert.are.same({
      "exec",
      "--sandbox",
      "workspace-write",
      "--cd",
      "/tmp/repo",
      "-",
    }, args)
  end)

  it("appends the model to codex exec args when one is set", function()
    ask_agent.setup({
      notify = function() end,
      model = "gpt-5-codex",
    })

    local args = ask_agent.build_args("/tmp/repo")

    assert.are.same({
      "exec",
      "--sandbox",
      "workspace-write",
      "--cd",
      "/tmp/repo",
      "--model",
      "gpt-5-codex",
      "-",
    }, args)
  end)

  it("defaults to the codex provider when none is set", function()
    assert.are.equal("codex", ask_agent.config.provider)

    local args = ask_agent.build_args("/tmp/repo")

    assert.are.same({
      "exec",
      "--sandbox",
      "workspace-write",
      "--cd",
      "/tmp/repo",
      "-",
    }, args)
  end)

  it("uses a git repository as the workspace root when one is found", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.git", "p")
    vim.fn.mkdir(dir .. "/lua", "p")

    assert.are.equal(dir, ask_agent.find_workspace_root(dir .. "/lua/example.lua"))
  end)

  it("falls back to cwd as the workspace root outside a git repository", function()
    local previous_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local expected_root = vim.fn.getcwd()

    local root = ask_agent.find_workspace_root(dir .. "/example.lua")

    vim.cmd("cd " .. vim.fn.fnameescape(previous_cwd))
    assert.are.equal(expected_root, root)
  end)

  it("builds a prompt with selection context", function()
    local prompt = ask_agent.build_prompt("rename this", {
      relative_path = "lua/example.lua",
      start_line = 3,
      end_line = 5,
      selected_text = "local old = true",
    })

    assert.is_true(prompt:find("rename this", 1, true) ~= nil)
    assert.is_true(prompt:find("File: lua/example.lua", 1, true) ~= nil)
    assert.is_true(prompt:find("Lines: 3%-5") ~= nil)
    assert.is_true(prompt:find("local old = true", 1, true) ~= nil)
  end)

  it("leads the prompt with the active provider label", function()
    local prompt = ask_agent.build_prompt("rename this", {
      relative_path = "lua/example.lua",
      start_line = 3,
      end_line = 5,
      selected_text = "local old = true",
    })

    assert.is_true(prompt:find("through Codex non-interactive mode", 1, true) ~= nil)
  end)

  it("shows nothing in the statusline before codex logs exist", function()
    assert.are.equal("", ask_agent.statusline())
  end)

  it("shows spinner and last message while codex is running", function()
    ask_agent.setup({
      notify = function() end,
      status_spinner = { "-", "\\" },
    })

    ask_agent.state.running = true
    ask_agent.state.spinner_index = 2
    ask_agent._test_append_log_lines({ "working" })

    local label = ask_agent.providers[ask_agent.config.provider].label
    assert.is_true(vim.startswith(ask_agent.statusline(), label .. " "))
    assert.are.equal(label .. " \\ working", ask_agent.statusline())
  end)

  it("shows nothing after codex stops", function()
    ask_agent._test_append_log_lines({ "done" })

    assert.are.equal("", ask_agent.statusline())
  end)

  it("raises a clear error for an unknown provider at setup", function()
    local ok, err = pcall(function()
      ask_agent.setup({
        notify = function() end,
        provider = "bogus",
      })
    end)

    assert.is_false(ok)
    assert.is_true(tostring(err):find("bogus", 1, true) ~= nil)
    assert.is_true(tostring(err):find("provider", 1, true) ~= nil)
  end)
end)
