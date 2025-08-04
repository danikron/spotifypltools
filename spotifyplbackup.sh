#! /bin/sh

SCRIPTPATH="$0"
while [ -h "$SCRIPTPATH" ]; do
	SCRIPTDIR="$(cd -P "$(dirname "$SCRIPTPATH")" >/dev/null && pwd)"
	SCRIPTPATH="$(readlink "$SCRIPTPATH")"
	[[ $SCRIPTPATH != /* ]] && SOURCE="$SCRIPTDIR/$SCRIPTPATH"
done
SCRIPTPATH="$(cd -P "$(dirname "$SCRIPTPATH")" >/dev/null && pwd)"

# Check for required files

if [[ ! -f "$SCRIPTPATH/auth" ]]; then
	>&2 echo "spotscript: could not find auth-file in working directory"
	exit 1
elif [[ ! -f "$SCRIPTPATH/playlists" ]]; then
	>&2 echo "spotscript: could not find playlists-file in working directory"
	exit 1
fi

# Fetch access token

seed_playlist=$(cat "$SCRIPTPATH/playlists" | grep 'seed:' | cut -d: -f2)
client_id=$(cat "$SCRIPTPATH/auth" | grep 'id:' | cut -d: -f2)
client_secret=$(cat "$SCRIPTPATH/auth" | grep 'secret:' | cut -d: -f2)
port=8082
redirect_uri=http%3A%2F%2Flocalhost%3A$port%2F
auth_endpoint=https://accounts.spotify.com/authorize/?response_type=code\&client_id=$client_id\&redirect_uri=$redirect_uri
scopes="playlist-read-collaborative playlist-modify-public playlist-modify-private"

if [[ ! $seed_playlist || ! $client_id || ! $client_secret ]]; then
	>&2 echo "spotscript: could not aqcuire necessary information from auth- and/or playlists-file"
	exit 1
fi

if [[ ! -z $scopes ]]; then
	encoded_scopes=$(echo $scopes| tr ' ' '%' | sed s/%/%20/g)
	auth_endpoint=$auth_endpoint\&scope=$encoded_scopes
fi

function fetch_token() {

	if [[ ! $nc_pid || ! $(ps | grep "$nc_pid") ]]; then
		echo "HTTP/1.1 200 OK\nAccess-Control-Allow-Origin:*\nContent-Length:65\n\n<html><script>open(location, '_self').close();</script></html>\n" | nc -l -c -p $port &
		nc_pid=$!
	fi

	xdg-open $auth_endpoint &> /dev/null
}

echo -n "Fetching access token ..."

while [[ ! $response ]]; do
	response=$(fetch_token)

	if [[ ! $response && ! $loop ]]; then
		loop=1
		echo -en "failed\nAccess token was not acquired. Retrying ..."
	elif [[ ! $response && $loop -le 10 ]]; then
		loop=$(($loop + 1))
		echo -n "."
	elif [[ ! $response ]]; then
		echo #
		>&2 echo "spotscript: failed to retrieve access token"
	fi

done

echo "done"

code=$(echo "$response" | grep GET | cut -d' ' -f 2 | cut -d'=' -f 2)
response=$(curl -s https://accounts.spotify.com/api/token \
	-H "Content-Type:application/x-www-form-urlencoded" \
	-H "Authorization: Basic $(printf $client_id:$client_secret | base64 -w 0)" \
	-d "grant_type=authorization_code&code=$code&redirect_uri=$redirect_uri")
	token=$(printf $response | cut -d'"' -f4)

# Prompt for confirmation

seed_name=$(curl -s -X GET "https://api.spotify.com/v1/users/$seed_playlist?fields=name" -H "Accept: application/json" -H "Authorization: Bearer $token" | awk -F'"' '{print $4}' | tr -d "\n")

echo #
read -p "This will backup the playlist \"$seed_name\" to working directory. Continue? [y/N] " -n 1 -r
echo #
echo #

if [[ $REPLY =~ ^[Yy]$ ]]; then

	# Fetch seed playlist total

	echo -n "Fetching seed playlist count ..."
	total=$(curl -s -X GET "https://api.spotify.com/v1/users/$seed_playlist/tracks?fields=total" -H "Accept: application/json" -H "Authorization: Bearer $token" | tr -dc '0-9')
	total=$(($total/100 + 1))
	echo "done"

	# Feth seed playlist items

	echo -n "Fetching seed playlist items "
	result=()
	result=$(curl -s  GET "https://api.spotify.com/v1/users/$seed_playlist/tracks?fields=items(track(artists(name),album(name),name,href))" -H "Accept: application/json" -H "Authorization: Bearer $token" | jq '.[]')
	echo -n "."

	for (( x=1; x<=$total; x++ )); do
		req="https://api.spotify.com/v1/users/$seed_playlist/tracks?fields=items(track(artists(name),album(name),name,href))&offset="
		let "off=$x*100"
		result+=$(curl -s -X GET "$req$off" -H "Accept: application/json" -H "Authorization: Bearer $token" | jq '.[]')
		echo -n "."
	done
	echo "done"
	echo -n "Exporting file .."
	echo $result | jq -s 'add' > $seed_name
	echo "done"

else
	echo -e "Screw it then!"
fi
