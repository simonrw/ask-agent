local M = {}

local defaults = {
  codex_cmd = "codex",
  sandbox = "workspace-write",
  model = nil,
  extra_args = {},
  notify = vim.notify,
  prompt_width = 72,
  prompt_height = 10,
  status_spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  status_update_interval_ms = 120,
  status_max_message_length = 80,
  log_height_ratio = 0.33,
  max_log_lines = 1000,
  live_reload = true,
  live_reload_interval_ms = 1000,
}

M.config = vim.deepcopy(defaults)
M.state = {
  running = false,
  last_message = "",
  spinner_index = 1,
  has_codex_output = false,
  logs = {},
  log_buffers = {},
}

local function notify(message, level)
  M.config.notify(message, level or vim.log.levels.INFO, { title = "ask-agent" })
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

local function append_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) or not lines or #lines == 0 then
    return
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

local function append_log_lines(lines, update_last_message)
  if not lines or #lines == 0 then
    return
  end
  if update_last_message == nil then
    update_last_message = true
  end

  local valid_log_buffers = {}
  for _, line in ipairs(lines) do
    table.insert(M.state.logs, line)
    if update_last_message then
      M.state.last_message = line
      M.state.has_codex_output = true
    end
  end

  for _, buf in ipairs(M.state.log_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      append_lines(buf, lines)
      table.insert(valid_log_buffers, buf)
    end
  end
  M.state.log_buffers = valid_log_buffers

  local overflow = #M.state.logs - M.config.max_log_lines
  if overflow > 0 then
    for _ = 1, overflow do
      table.remove(M.state.logs, 1)
    end
  end
end

local function normalize_job_lines(data)
  local lines = {}
  for _, line in ipairs(data or {}) do
    if line ~= "" then
      table.insert(lines, line)
    end
  end
  return lines
end

local function checktime()
  if M.config.live_reload then
    vim.cmd.checktime()
  end
end

local function open_logs()
  local previous_win = vim.api.nvim_get_current_win()
  local height = math.max(3, math.floor(vim.o.lines * M.config.log_height_ratio))

  vim.cmd("botright " .. height .. "split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "codex-log", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("wrap", true, { win = win })

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, silent = true, desc = "Close Codex logs" })

  if #M.state.logs == 0 then
    append_lines(buf, { "No Codex logs yet." })
  else
    append_lines(buf, M.state.logs)
  end
  table.insert(M.state.log_buffers, buf)

  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  return { buf = buf, win = win }
end

local function redrawstatus()
  vim.cmd.redrawstatus()
end

local function spinner_frames()
  local frames = M.config.status_spinner or defaults.status_spinner
  if #frames == 0 then
    return defaults.status_spinner
  end
  return frames
end

local function start_status_timer()
  local timer = vim.loop.new_timer()
  timer:start(M.config.status_update_interval_ms, M.config.status_update_interval_ms, function()
    vim.schedule(function()
      local frames = spinner_frames()
      M.state.spinner_index = (M.state.spinner_index % #frames) + 1
      redrawstatus()
    end)
  end)
  return timer
end

local function stop_status_timer(timer)
  if not timer then
    return
  end

  timer:stop()
  timer:close()
  redrawstatus()
end

local function reset_run_state()
  M.state.running = true
  M.state.last_message = "Codex started"
  M.state.spinner_index = 1
  M.state.has_codex_output = false
  M.state.logs = {}
  for _, buf in ipairs(M.state.log_buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    end
  end
  append_log_lines({ "Codex started..." }, false)
end

local function truncate_message(message)
  local max = M.config.status_max_message_length
  if not max or max <= 0 or #message <= max then
    return message
  end

  return string.sub(message, 1, math.max(1, max - 3)) .. "..."
end

function M.statusline()
  if not M.state.running then
    return ""
  end

  local message = truncate_message(M.state.last_message or "")
  message = message:gsub("%%", "%%%%")

  local frames = spinner_frames()
  local spinner = frames[M.state.spinner_index] or frames[1] or "*"
  if message == "" then
    return "Codex " .. spinner
  end
  return "Codex " .. spinner .. " " .. message
end

local function start_reload_timer()
  if not M.config.live_reload then
    return nil
  end

  local timer = vim.loop.new_timer()
  timer:start(M.config.live_reload_interval_ms, M.config.live_reload_interval_ms, function()
    vim.schedule(checktime)
  end)
  return timer
end

local function stop_reload_timer(timer)
  if not timer then
    return
  end

  timer:stop()
  timer:close()
end

local function run_codex(prompt, repo_root)
  if vim.bo.modified then
    vim.cmd.write()
  end

  local args = M.build_args(repo_root)
  local stderr = {}
  local reload_timer = start_reload_timer()

  reset_run_state()
  local status_timer = start_status_timer()
  redrawstatus()

  local job_id = vim.fn.jobstart(vim.list_extend({ M.config.codex_cmd }, args), {
    cwd = repo_root,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      local lines = normalize_job_lines(data)
      if #lines == 0 then
        return
      end

      vim.schedule(function()
        append_log_lines(lines)
        checktime()
        redrawstatus()
      end)
    end,
    on_stderr = function(_, data)
      local lines = normalize_job_lines(data)
      if #lines == 0 then
        return
      end

      vim.list_extend(stderr, lines)
      vim.schedule(function()
        append_log_lines(lines)
        checktime()
        redrawstatus()
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        stop_reload_timer(reload_timer)
        M.state.running = false
        stop_status_timer(status_timer)
        checktime()

        if code == 0 then
          append_log_lines({ "", "Codex finished successfully." }, false)
          if not M.state.has_codex_output then
            M.state.last_message = "Codex finished successfully."
          end
          redrawstatus()
          return
        end

        append_log_lines({ "", "Codex failed with exit code " .. code .. "." }, false)
        if not M.state.has_codex_output then
          M.state.last_message = "Codex failed with exit code " .. code .. "."
        end
        redrawstatus()

        local detail = table.concat(vim.list_slice(stderr, 1, 3), "\n")
        local message = "Codex failed with exit code " .. code
        if detail ~= "" then
          message = message .. "\n" .. detail
        end
        notify(message, vim.log.levels.ERROR)
      end)
    end,
  })

  if job_id <= 0 then
    stop_reload_timer(reload_timer)
    M.state.running = false
    stop_status_timer(status_timer)
    append_log_lines({ "Failed to start Codex job." }, false)
    M.state.last_message = "Failed to start Codex job."
    redrawstatus()
    notify("Failed to start Codex job", vim.log.levels.ERROR)
    return
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")
end

function M._test_normalize_job_lines(data)
  return normalize_job_lines(data)
end

function M._test_append_lines(buf, lines)
  return append_lines(buf, lines)
end

function M._test_append_log_lines(lines)
  return append_log_lines(lines)
end

function M._test_open_logs()
  return open_logs()
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

local function run_or_prompt(context, initial_prompt)
  initial_prompt = vim.trim(initial_prompt or "")

  if initial_prompt ~= "" then
    run_codex(M.build_prompt(initial_prompt, context), context.repo_root)
    return
  end

  open_prompt(context)
end

function M.apply_selection(initial_prompt)
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

  run_or_prompt({
    repo_root = repo_root,
    relative_path = relative_path,
    start_line = selection.start_line,
    end_line = selection.end_line,
    selected_text = selection.text,
  }, initial_prompt)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  M.state.running = false
  M.state.last_message = ""
  M.state.spinner_index = 1
  M.state.has_codex_output = false
  M.state.logs = {}
  M.state.log_buffers = {}

  vim.api.nvim_create_user_command("CodexApplySelection", function(command)
    M.apply_selection(command.args)
  end, { nargs = "*", range = true, desc = "Ask Codex to change the visual selection in place" })

  vim.api.nvim_create_user_command("CodexApplyLogs", function()
    open_logs()
  end, { desc = "Open Codex apply logs" })
end

return M
