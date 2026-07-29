echo "=== LS2 role dirs (where com.palm.imlibpurple.json / *.call.json live) ==="
for d in /usr/share/ls2/roles /var/palm/ls2/roles /usr/share/luna-service2/roles /etc/luna-service2/roles; do
  [ -d "$d" ] && echo "DIR $d:" && ls -R "$d" 2>/dev/null | grep -iE "imlibpurple|\.call\.|pub:|prv:|roles" | head
done
echo "=== find the actual imlibpurple role files on device ==="
find / -name "com.palm.imlibpurple.json" 2>/dev/null | grep -i role | head
find / -name "com.palm.telegram.call.json" -o -name "com.palm.signal.call.json" 2>/dev/null | head
echo "=== dbus system-services dir (for .call.service) ==="
find / -name "com.palm.signal.call.service" 2>/dev/null | head
echo "=== is a Teams account configured? ==="
luna-send -n 1 palm://com.palm.service.accounts/listAccounts '{}' 2>/dev/null | sed 's/{"_kind"/\n{"_kind"/g' | grep -oE '"templateId":"com.palm.(teams|telegram|whatsapp|signal)"' | sort -u
echo "=== account template on disk ==="
ls -la /usr/palm/public/accounts/com.palm.teams/com.palm.teams.json 2>/dev/null
