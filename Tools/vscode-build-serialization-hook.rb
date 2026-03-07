#!/usr/bin/env ruby

require "json"

def shell_quote(value)
  "'#{value.to_s.gsub("'", %q('\\''))}'"
end

def build_command?(command)
  return false if command.nil? || command.empty?
  return false if command.include?("Tools/serialized-build-command.sh")

  lower = command.downcase
  return true if lower.include?("tools/build.sh")
  return true if lower.include?("tools/build-and-launch.sh")
  return true if lower.include?("swift build") || lower.include?("swift test")

  if lower.include?("xcodebuild")
    return false if lower.include?("-showbuildsettings")
    return false if lower.include?("-list")
    return false if lower.include?("-exportarchive")
    return false if lower.include?("-exportlocalizations")
    return true
  end

  false
end

def output(updated_input, message)
  puts JSON.generate(
    {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: updated_input,
        additionalContext: message
      }
    }
  )
end

payload = JSON.parse(STDIN.read)
tool_name = payload["tool_name"]
tool_input = payload["tool_input"] || {}

case tool_name
when "run_in_terminal"
  command = tool_input["command"].to_s
  if build_command?(command)
    updated_input = tool_input.merge(
      "command" => "./Tools/serialized-build-command.sh #{shell_quote(command)}"
    )
    output(updated_input, "Serialized build command through the shared Peel build lock.")
  end
when "create_and_run_task"
  task = tool_input["task"] || {}
  command = task["command"].to_s
  args = Array(task["args"])
  full_command = ([command] + args.map { |arg| shell_quote(arg) }).join(" ").strip

  if build_command?(full_command)
    updated_task = task.merge(
      "command" => "./Tools/serialized-build-command.sh",
      "args" => [full_command]
    )
    updated_input = tool_input.merge("task" => updated_task)
    output(updated_input, "Serialized task build command through the shared Peel build lock.")
  end
end