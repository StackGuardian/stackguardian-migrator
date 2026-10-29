x=$(printf a | tr -c 'A-Za-z0-9_-\n' '-')
sed -i 's/a/b/' f
sed -i '' 's/a/b/' f
sed -E -i 's/a/b/' f
sed -i.bak 's/a/b/' f
sed -r 's/a+/b/' f
sed "s#x##g" | while read -r l; do :; done
date -d yesterday
stat -c %s f
readlink -f x
grep -oP 'x' f
printf x | xargs -r echo
find . -printf '%p'
n=$(nproc)
timeout 5 curl x
declare -A m
local -n ref=x
mapfile -t a < f
echo "${x,,}"
echo "${x@Q}"
cmd &>> log
echo "${a[-1]}"
[[ -v x ]]
wait -n
echo $EPOCHSECONDS
y="${v:-{}}"
z="${v:-"{}"}"
echo -e "a\n"
s="${s//\$\{/\$\$\{}"
