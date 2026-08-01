-- driver.applescript — the UI for "Shrink Design Zip".
--
-- Handles three entry points:
--   * a .zip dropped on the app icon
--   * a .zip dropped on the open app window
--   * a plain double-click, which opens a file chooser
--
-- Runs shrink-design-zip.sh, then reports the result as a dialog. All errors
-- surface as dialogs; nothing is written to a terminal the user cannot see.

-- Resources live next to the compiled script inside the bundle. Deriving the
-- path from the bundle itself works for both the run and open handlers.
on resourcesDir()
	return (POSIX path of (path to me)) & "Contents/Resources"
end resourcesDir

on run
	-- Double-clicked with no file: ask for one.
	activate
	set chosen to choose file with prompt "Choose the Claude Design .zip to shrink:" of type {"public.zip-archive"}
	processFile(POSIX path of chosen, resourcesDir())
end run

-- Dropping files onto the app icon routes here.
on open theItems
	set resDir to resourcesDir()
	set zips to {}
	repeat with f in theItems
		set p to POSIX path of f
		if p ends with ".zip" or p ends with ".ZIP" then set end of zips to p
	end repeat

	if (count of zips) = 0 then
		activate
		display dialog "That is not a .zip file." & return & return & ¬
			"Drop the .zip you downloaded from Claude Design." ¬
			buttons {"OK"} default button "OK" with icon stop with title "Shrink Design Zip"
		return
	end if

	repeat with z in zips
		processFile(z, resDir)
	end repeat
end open

on processFile(zipPath, resDir)
	set scriptPath to resDir & "/shrink-design-zip.sh"

	-- Show a non-blocking notification so a 30-60 second run does not look hung.
	display notification "Shrinking " & shortName(zipPath) & "…" with title "Shrink Design Zip"

	-- Run the shrinker. Output is captured for the summary dialog; a non-zero
	-- exit still returns output, so the message can explain what happened.
	set cmd to "cd " & quoted form of resDir & " && /bin/bash " & quoted form of scriptPath & ¬
		" " & quoted form of zipPath & " 2>&1"
	set exitCode to 0
	try
		set outText to do shell script cmd
	on error errMsg number errNum
		set outText to errMsg
		set exitCode to errNum
	end try

	set outPath to optimizedPath(zipPath)
	set okExists to false
	try
		do shell script "test -f " & quoted form of outPath
		set okExists to true
	end try

	if okExists then
		set beforeMB to sizeMB(zipPath)
		set afterMB to sizeMB(outPath)
		set pct to "0"
		try
			set pct to do shell script "awk -v a=" & beforeMB & " -v b=" & afterMB & ¬
				" 'BEGIN{printf \"%.0f\", (a-b)*100/a}'"
		end try

		if exitCode = 0 then
			set msg to "Done." & return & return & ¬
				beforeMB & " MB  →  " & afterMB & " MB   (" & pct & "% smaller)" & return & return & ¬
				"Saved as:" & return & shortName(outPath)
			set dlgIcon to note
		else
			-- The script produced a file but could not reach the target.
			set msg to "Shrunk as far as possible, but it is still over the limit." & return & return & ¬
				beforeMB & " MB  →  " & afterMB & " MB   (" & pct & "% smaller)" & return & return & ¬
				"Saved as:" & return & shortName(outPath) & return & return & ¬
				"You can still try uploading it."
			set dlgIcon to caution
		end if

		activate
		display dialog msg buttons {"OK", "Show in Finder"} default button "Show in Finder" ¬
			with icon dlgIcon with title "Shrink Design Zip"
		if button returned of result is "Show in Finder" then
			tell application "Finder"
				reveal (POSIX file outPath as alias)
				activate
			end tell
		end if
	else
		activate
		display dialog "Could not shrink that file." & return & return & ¬
			lastLines(outText, 6) ¬
			buttons {"OK"} default button "OK" with icon stop with title "Shrink Design Zip"
	end if
end processFile

on optimizedPath(p)
	set d to do shell script "dirname " & quoted form of p
	set b to do shell script "basename " & quoted form of p & " .zip"
	return d & "/" & b & "-optimized.zip"
end optimizedPath

on sizeMB(p)
	try
		return do shell script "stat -f%z " & quoted form of p & ¬
			" | awk '{printf \"%.1f\", $1/1000000}'"
	on error
		return "?"
	end try
end sizeMB

on shortName(p)
	try
		return do shell script "basename " & quoted form of p
	on error
		return p
	end try
end shortName

on lastLines(t, n)
	try
		return do shell script "printf %s " & quoted form of t & " | tail -n " & n
	on error
		return t
	end try
end lastLines
