-- Jellyfin Control — single app for all Jellyfin operations

on run
	set menuChoice to button returned of (display dialog "Jellyfin Control" buttons {"Stop Server", "Scan Library", "Show URL"} default button "Show URL" with title "Jellyfin" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text))
	
	if menuChoice is "Show URL" then
		showURL()
	else if menuChoice is "Scan Library" then
		scanLibrary()
	else if menuChoice is "Stop Server" then
		stopServer()
	end if
end run

on showURL()
	set theIP to do shell script "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo ''"
	
	if theIP is "" then
		display dialog "Not connected to WiFi." buttons {"OK"} default button "OK" with title "Jellyfin" with icon caution
		return
	end if
	
	set theHostname to do shell script "hostname -s"
	set urlMsg to "Jellyfin is available at:" & return & return & "  http://" & theIP & ":8096" & return & "  http://" & theHostname & ".local:8096" & return & return & "Share either URL with anyone on the same WiFi."
	
	set urlAction to button returned of (display dialog urlMsg buttons {"Open in Browser", "Troubleshoot", "OK"} default button "OK" with title "Jellyfin" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text))
	
	if urlAction is "Open in Browser" then
		open location "http://localhost:8096"
	else if urlAction is "Troubleshoot" then
		troubleshoot()
	end if
end showURL

on scanLibrary()
	set isRunning to do shell script "pgrep -f 'Jellyfin Server' > /dev/null 2>&1 && echo 'yes' || echo 'no'"
	
	if isRunning is "no" then
		display dialog "Jellyfin is not running. Start it first." buttons {"OK"} default button "OK" with title "Jellyfin" with icon caution
		return
	end if
	
	try
		do shell script "TOKEN=$(curl -s --max-time 10 -X POST http://localhost:8096/Users/AuthenticateByName -H 'Content-Type: application/json' -H 'X-Emby-Authorization: MediaBrowser Client=\"Control\", Device=\"Mac\", DeviceId=\"ctrl1\", Version=\"1.0\"' -d '{\"Username\": \"pjdruck\", \"Pw\": \"8544\"}' | python3 -c \"import sys,json; print(json.load(sys.stdin)['AccessToken'])\") && curl -s --max-time 10 -X POST 'http://localhost:8096/Library/Refresh' -H \"X-Emby-Token: $TOKEN\""
		display dialog "Library scan triggered — Jellyfin will pick up new films shortly." buttons {"OK"} default button "OK" with title "Jellyfin" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text)
	on error
		display dialog "Could not connect to Jellyfin. Is it running?" buttons {"OK"} default button "OK" with title "Jellyfin" with icon caution
	end try
end scanLibrary

on stopServer()
	set isRunning to do shell script "pgrep -f 'Jellyfin Server' > /dev/null 2>&1 && echo 'yes' || echo 'no'"
	
	if isRunning is "no" then
		display dialog "Jellyfin is not running." buttons {"OK"} default button "OK" with title "Jellyfin" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text)
		return
	end if
	
	set confirmStop to button returned of (display dialog "Shut down Jellyfin server?" & return & return & "This will stop the server, caffeinate, and the watchdog. Your Mac will sleep normally again." buttons {"Cancel", "Stop"} default button "Cancel" with title "Jellyfin" with icon caution)
	
	if confirmStop is "Stop" then
		try
			do shell script "TOKEN=$(curl -s --max-time 5 -X POST http://localhost:8096/Users/AuthenticateByName -H 'Content-Type: application/json' -H 'X-Emby-Authorization: MediaBrowser Client=\"Control\", Device=\"Mac\", DeviceId=\"ctrl1\", Version=\"1.0\"' -d '{\"Username\": \"pjdruck\", \"Pw\": \"8544\"}' | python3 -c \"import sys,json; print(json.load(sys.stdin)['AccessToken'])\") && curl -s --max-time 5 -X POST 'http://localhost:8096/System/Shutdown' -H \"X-Emby-Token: $TOKEN\" 2>/dev/null; sleep 3; pkill -f 'Jellyfin Server' 2>/dev/null; pkill -f 'jellyfin-watchdog' 2>/dev/null; pkill -f caffeinate 2>/dev/null; osascript -e 'tell application \"Jellyfin\" to quit' 2>/dev/null"
		end try
		
		display dialog "Jellyfin stopped. Your Mac will sleep normally now." buttons {"OK"} default button "OK" with title "Jellyfin" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text)
	end if
end stopServer

on troubleshoot()
	set results to ""
	
	-- Check Jellyfin running
	set isRunning to do shell script "pgrep -f 'Jellyfin Server' > /dev/null 2>&1 && echo 'yes' || echo 'no'"
	if isRunning is "yes" then
		set results to results & "✓  Jellyfin is running" & return
	else
		set results to results & "✗  Jellyfin is NOT running" & return
	end if
	
	-- Check server responding
	set isResponding to do shell script "curl -s -o /dev/null --connect-timeout 3 http://localhost:8096/web/index.html 2>/dev/null && echo 'yes' || echo 'no'"
	if isResponding is "yes" then
		set results to results & "✓  Server responding on port 8096" & return
	else
		set results to results & "✗  Server NOT responding" & return
	end if
	
	-- Check drive
	set hasDrive to do shell script "[ -d '/Volumes/Backup Plus/All Movies' ] && echo 'yes' || echo 'no'"
	if hasDrive is "yes" then
		set movieCount to do shell script "ls -d '/Volumes/Backup Plus/All Movies/'*/*/ 2>/dev/null | wc -l | tr -d ' '"
		set results to results & "✓  Hard drive mounted (" & movieCount & " movie folders)" & return
	else
		set results to results & "✗  Hard drive NOT mounted" & return
	end if
	
	-- Check WiFi
	set theIP to do shell script "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo ''"
	if theIP is not "" then
		set results to results & "✓  WiFi connected (" & theIP & ")" & return
	else
		set results to results & "✗  Not connected to WiFi" & return
	end if
	
	-- Check caffeinate
	set hasCaff to do shell script "pgrep caffeinate > /dev/null 2>&1 && echo 'yes' || echo 'no'"
	if hasCaff is "yes" then
		set results to results & "✓  Sleep prevention active" & return
	else
		set results to results & "✗  Sleep prevention NOT active" & return
	end if
	
	set fixAction to button returned of (display dialog results buttons {"Fix Issues", "OK"} default button "OK" with title "Jellyfin Troubleshooter" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text))
	
	if fixAction is "Fix Issues" then
		if isRunning is "no" then
			do shell script "open -a Jellyfin"
			delay 5
		end if
		if isResponding is "no" and isRunning is "yes" then
			do shell script "pkill -f 'Jellyfin Server' 2>/dev/null; sleep 2; open -a Jellyfin"
			delay 8
		end if
		display dialog "Attempted fixes. Check again to verify." buttons {"Check Again", "OK"} default button "OK" with title "Jellyfin" with icon alias ((POSIX file "/Applications/Jellyfin.app/Contents/Resources/AppIcon.icns") as text)
		if button returned of result is "Check Again" then
			troubleshoot()
		end if
	end if
end troubleshoot

