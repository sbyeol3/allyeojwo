# 알려줘 (ClaudeBell)

여러 Claude Code 세션을 macOS 메뉴 막대 하나에서 보고, 작업이 끝나거나 확인이 필요하면 말풍선과 노래로 알려 주는 앱이에요.

- 메뉴 막대 🔔 에 확인할 세션 수가 표시되고, 누르면 세션 목록이 나와요
- 말풍선을 클릭하면 그 세션의 VS Code 창으로 이동하고, 좌우로 밀면 닫혀요
- 설정에서 캐릭터 이미지(최대 5장), 알림 노래, 재생 시간 등을 바꿀 수 있어요

## 요구 사항

- macOS 13 이상
- Xcode Command Line Tools (`xcode-select --install`)

## 설치

경로가 `~/.claude/bell` 로 고정되어 있으니 그 위치에 받아 주세요.

```sh
git clone https://github.com/sbyeol3/allyeojwo.git ~/.claude/bell
~/.claude/bell/build.sh   # ~/Applications/ClaudeBell.app 에 설치
```

`~/.claude/settings.json` 에 훅을 추가해요 (이미 `hooks` 가 있다면 합쳐 주세요).

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/bell/notify.sh prompt" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/bell/notify.sh stop" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/bell/notify.sh notification" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "~/.claude/bell/notify.sh end" }] }]
  }
}
```

훅이 처음 불릴 때 앱이 자동으로 켜져요. 설정 창은 `~/Applications/ClaudeBell.app` 을 직접 열거나 메뉴 막대의 **설정…** 에서 열 수 있어요.

## 업데이트

```sh
git -C ~/.claude/bell pull && ~/.claude/bell/build.sh
```

## License

MIT
