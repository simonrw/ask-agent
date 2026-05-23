local M = {}

local defaults = {
  codex_cmd = "codex",
  sandbox = "workspace-write",
  model = nil,
  extra_args = {},
  notify = vim.notify,
  prompt_width = 72,
  prompt_height = 10,
}

M.config = vim.deepcopy(defaults)

local function notify(message, level)
  M.config.notify(message, level or vim.log.levels.INFO, { title = "codex-apply" })
end

local function path_join(...)
  return table.concat({ ... }, "/")
end

local function dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

local function file_exists(path)
  return vim.loop.fs_stat(path) ~= nil
end

function M.find_repo_root(start_path)
  local path = vim.fn.fnamemodify(start_path, ":p")

  if file_exists(path) and vim.loop.fs_stat(path).type == "file" then
    path = dirname(path)
  end

  while path and path ~= "" do
    if file_exists(path_join(path, ".git")) then
      return path
    end

    local parent = dirname(path)
    if parent == path then
      break
    end
    path = parent
  end

  return nil
end

local function normalize_range(start_pos, end_pos)
  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  return start_line, start_col, end_line, end_col
end

function M.get_visual_selection(bufnr)
  bufnr = bufnr or 0

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line, start_col, end_line, end_col = normalize_range(start_pos, end_pos)

  if start_line == 0 or end_line == 0 then
    return nil, "No visual selection found"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil, "Selected text is empty"
  end

  local mode = vim.fn.visualmode()
  if mode == "\22" then
    for i, line in ipairs(lines) do
      lines[i] = string.sub(line, start_col, end_col)
    end
  elseif mode ~= "V" then
    lines[1] = string.sub(lines[1], start_col)
    if #lines == 1 then
      lines[1] = string.sub(lines[1], 1, end_col - start_col + 1)
    else
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
  end

  return {
    text = table.concat(lines, "\n"),
    start_line = start_line,
    end_line = end_line,
    mode = mode,
  }, nil
end

function M.build_prompt(user_prompt, context)
  return table.concat({
    "You are editing a repository from Neovim through Codex non-interactive mode.",
    "",
    "User instruction:",
    user_prompt,
    "",
    "Focus selection:",
    "File: " .. context.relative_path,
    "Lines: " .. context.start_line .. "-" .. context.end_line,
    "",
    "Selected text:",
    "```",
    context.selected_text,
    "```",
    "",
    "Implement the requested change directly in the repository.",
    "Use the selected text as the focus, but update related files when needed.",
    "Keep the change minimal and avoid unrelated refactors.",
  }, "\n")
end

function M.build_args(repo_root)
  local args = { "exec", "--sandbox", M.config.sandbox, "--cd", repo_root }

  if M.config.model and M.config.model ~= "" then
    vim.list_extend(args, { "--model", M.config.model })
  end

  vim.list_extend(args, M.config.extra_args or {})
  table.insert(args, "-")

  return args
end

local function close_prompt(win, buf)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

local function run_codex(prompt, repo_root)
  if vim.bo.modified then
    vim.cmd.write()
  end

  local args = M.build_args(repo_root)
  local stderr = {}

  notify("Codex started", vim.log.levels.INFO)

  vim.system({ M.config.codex_cmd, unpack(args) }, {
    cwd = repo_root,
    stdin = prompt,
    text = true,
  }, function(result)
    vim.schedule(function()
      if result.stderr and result.stderr ~= "" then
        stderr = vim.split(result.stderr, "\n", { trimempty = true })
      end

      if result.code == 0 then
        vim.cmd.checktime()
        notify("Codex finished and files were checked for reload", vim.log.levels.INFO)
        return
      end

      local detail = table.concat(vim.list_slice(stderr, 1, 3), "\n")
      local message = "Codex failed with exit code " .. result.code
      if detail ~= "" then
        message = message .. "\n" .. detail
      end
      notify(message, vim.log.levels.ERROR)
    end)
  end)
end

local function submit_prompt(win, buf, context)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local user_prompt = vim.trim(table.concat(lines, "\n"))

  if user_prompt == "" then
    close_prompt(win, buf)
    notify("Cancelled: prompt was empty", vim.log.levels.WARN)
    return
  end

  close_prompt(win, buf)
  run_codex(M.build_prompt(user_prompt, context), context.repo_root)
end

local function open_prompt(context)
  local width = math.min(M.config.prompt_width, vim.o.columns - 4)
  local height = math.min(M.config.prompt_height, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Codex prompt ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    close_prompt(win, buf)
    notify("Codex prompt cancelled", vim.log.levels.INFO)
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set("n", "<CR>", function()
    submit_prompt(win, buf, context)
  end, { buffer = buf, silent = true })

  vim.keymap.set("i", "<CR>", function()
    submit_prompt(win, buf, context)
  end, { buffer = buf, silent = true })

  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, silent = true })
  vim.keymap.set("i", "<C-j>", "<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<S-CR>", "i<CR><Esc>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<C-j>", "i<CR><Esc>", { buffer = buf, silent = true })

  vim.cmd.startinsert()
end

function M.apply_selection()
  local file_path = vim.api.nvim_buf_get_name(0)
  if file_path == "" then
    notify("Current buffer has no file path", vim.log.levels.ERROR)
    return
  end

  local repo_root = M.find_repo_root(file_path)
  if not repo_root then
    notify("CodexApplySelection requires a Git repository", vim.log.levels.ERROR)
    return
  end

  local selection, err = M.get_visual_selection(0)
  if err then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local relative_path = vim.fn.fnamemodify(file_path, ":.")
  if string.sub(file_path, 1, #repo_root + 1) == repo_root .. "/" then
    relative_path = string.sub(file_path, #repo_root + 2)
  end

  open_prompt({
    repo_root = repo_root,
    relative_path = relative_path,
    start_line = selection.start_line,
    end_line = selection.end_line,
    selected_text = selection.text,
  })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("CodexApplySelection", function()
    M.apply_selection()
  end, { range = true, desc = "Ask Codex to change the visual selection in place" })
end

return M
