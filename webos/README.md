# webOS — LG TV

Sideload apps onto the LG TV (`Rehab-LG`, `192.168.0.196`) with the webOS CLI.

## 1. Install the CLI

Needs Node 20. Node 23 and later removed `util.isDate`, which `ares-cli` still
calls. See [Known issues](#known-issues).

```bash
npm install -g @webosose/ares-cli
ares-setup-device --list
```

## 2. Turn on Developer Mode on the TV

1. Create an LG developer account at <https://developer.lge.com>.
2. On the TV, install **Developer Mode** from the LG Content Store.
3. Open the app. Sign in with the same account.
4. Turn on **Dev Mode Status**. The TV reboots.
5. Reopen the app. Turn on **Key Server**.
6. Note the 6-character passphrase on screen.

The session lasts 1000 hours. Reopen the app and press **Extend** before it
ends. Apps stay installed but refuse to launch once it expires.

## 3. Add the device

Fetch the key. The TV serves it on port 9991:

```bash
curl -o ~/.ssh/webos_rsa http://192.168.0.196:9991/webos_rsa
chmod 600 ~/.ssh/webos_rsa
```

Register the device. The account is always `prisoner`, never `root`:

```bash
ares-setup-device -a Rehab-LG \
  -i "host=192.168.0.196" -i "port=9922" -i "username=prisoner" \
  -i "privatekey=webos_rsa" -i "passphrase=XXXXXX"
```

Test it. An empty list means the connection works:

```bash
ares-install -d Rehab-LG --list
```

Use `-m` instead of `-a` to update a device that already exists. Toggling Dev
Mode off and on makes a new key and passphrase, so repeat this step.

`ares-device -i` does not work here. A retail TV denies that Luna call.

## 4. Install Stremio

```bash
gh release download v1.0.0 -R Balazsmi/Stremio-LG-TV
ares-install -d Rehab-LG org.balazs.stremio-wrapper_1.0.0_all.ipk
ares-install -d Rehab-LG --list
ares-launch -d Rehab-LG org.balazs.stremio-wrapper
```

The app is an iframe wrapper around `https://tv.strem.io`.

## Shell access

`ares-shell` is broken on retail TVs. It prepends `source /etc/profile`, which
the `prisoner` jail does not have. Use plain `ssh` instead:

```bash
ssh tv pwd        # /media/developer
```

The `tv` host block lives in the `dotfiles` repo at `ssh/config`. The TV offers
`ssh-rsa` host keys only, so that block sets `HostKeyAlgorithms +ssh-rsa` and
`PubkeyAcceptedKeyTypes +ssh-rsa`.

## Known issues

Three bugs in `ares-cli` 2.4.0. Node 20 fixes the first. The other two need
edits inside the installed package, which `npm update` undoes.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `TypeError: isDate is not a function` | `ssh2-streams` calls `util.isDate`, removed in Node 23 | Use Node 20 |
| `rm: can't remove '/media/developer/temp'` | Installer deletes a root-owned directory that `prisoner` cannot touch | In `lib/install.js`, clear the contents instead: `mkdir -p DIR && rm -rf DIR/*` |
| `can't open '/etc/profile'` | `ares-shell` assumes a login shell | Use `ssh` instead |

## References

- [Balazsmi/Stremio-LG-TV](https://github.com/Balazsmi/Stremio-LG-TV) — the Stremio `.ipk`
- [webos-tools/cli](https://github.com/webos-tools/cli) — CLI source
- [CLI user guide](https://www.webosose.org/docs/tools/sdk/cli/cli-user-guide)
