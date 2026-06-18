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

    assert.are.equal("Codex \\ working", ask_agent.statusline())
  end)

  it("shows nothing after codex stops", function()
    ask_agent._test_append_log_lines({ "done" })

    assert.are.equal("", ask_agent.statusline())
  end)
end)
