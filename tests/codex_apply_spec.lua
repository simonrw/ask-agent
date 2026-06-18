local codex_apply = require("codex_apply")

describe("codex_apply", function()
  before_each(function()
    codex_apply.setup({
      notify = function() end,
    })
  end)

  it("builds codex exec args", function()
    local args = codex_apply.build_args("/tmp/repo")

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
    local prompt = codex_apply.build_prompt("rename this", {
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
    assert.are.equal("", codex_apply.statusline())
  end)

  it("shows spinner and last message while codex is running", function()
    codex_apply.setup({
      notify = function() end,
      status_spinner = { "-", "\\" },
    })

    codex_apply.state.running = true
    codex_apply.state.spinner_index = 2
    codex_apply._test_append_log_lines({ "working" })

    assert.are.equal("Codex \\ working", codex_apply.statusline())
  end)

  it("shows nothing after codex stops", function()
    codex_apply._test_append_log_lines({ "done" })

    assert.are.equal("", codex_apply.statusline())
  end)
end)
