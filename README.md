# ghostel-ai

Natural-language commands and AI completions for
[ghostel](https://github.com/dakra/ghostel)'s line mode.

`ghostel-ai-mode` does three things at a shell prompt in
`ghostel-line-mode`:

- **Translate.** On `RET`, [TypeSafe](https://typesafe.ai)'s Jev
  classifier decides within milliseconds whether the input is a shell
  command or an instruction in natural language.  Instructions are
  turned into a command by [gptel](https://github.com/karthink/gptel)
  and put back into the input for review; press `RET` again to run
  it, or edit it and ask again.  Input starting with `#` skips the
  classifier and is translated right away.
- **Confirm.** Input that Jev rates as destructive asks `y-or-n`
  before it is sent.
- **Complete.** While typing, `completion-preview-mode` shows a
  suggestion after point.  A shell-history entry that starts with the
  input wins instantly; otherwise gptel continues the line, given the
  shell, the directory listing, the last lines of terminal output and
  related history.  `TAB` accepts.

## Requirements

- Emacs 30.1 (for `completion-preview-mode`)
- ghostel 0.57.0, gptel 0.9.9
- A TypeSafe API key in `ghostel-ai-typesafe-api-key` (a string or a
  function returning it, e.g. an auth-source lookup) or the
  `TYPESAFE_API_KEY` environment variable
- A configured gptel backend

## Install

```emacs-lisp
(use-package ghostel-ai
  :vc (:url "https://github.com/dakra/ghostel-ai")
  :hook (ghostel-mode . ghostel-ai-mode))
```

## Options

|Option                                                       |Default                             |Meaning                                                   |
|-------------------------------------------------------------|------------------------------------|----------------------------------------------------------|
|`ghostel-ai-routes`                                          |`#` translates, `cd ls ...` go to shell|Regexps that skip the classifier                       |
|`ghostel-ai-shell-threshold`                                 |0.5                                 |Below this shell probability the input is translated      |
|`ghostel-ai-danger-threshold`                                |0.5                                 |Above this destructive probability a confirmation is asked|
|`ghostel-ai-typesafe-timeout`                                |2                                   |Seconds to wait for the classifier before sending as-is   |
|`ghostel-ai-translate-timeout`                               |30                                  |Seconds to wait for a translation before aborting it      |
|`ghostel-ai-completion-delay`                                |0.5                                 |Idle seconds before a completion is suggested             |
|`ghostel-ai-completion-timeout`                              |10                                  |Seconds to wait for the model per completion              |
|`ghostel-ai-gptel-backend`, `ghostel-ai-gptel-model`         |nil                                 |Override gptel's defaults for this package                |
|`ghostel-ai-shell-question`, `ghostel-ai-danger-question`    |see source                          |The two Jev questions                                     |
|`ghostel-ai-translate-prompt`, `ghostel-ai-completion-prompt`|see source                          |System prompts for translation and completion             |

The prompts are `format-spec` templates: `%s` is the shell name
(`zsh`, `fish`, `nu`, ...), `%o` the operating system and `%d` the
working directory.

`ghostel-ai-routes` is an alist of `(REGEXP . ROUTE)`, first match
wins, unmatched input goes to the classifier.  `shell` sends the input
as typed, `translate` sends the input minus the matched text to gptel,
`classify` asks Jev.  `(("" . shell))` turns the classifier off.

To send a line as typed, skipping routes and classifier, press
`C-u RET` or bind `ghostel-ai-send-to-shell`:

```emacs-lisp
(keymap-set ghostel-line-mode-map "C-<return>" #'ghostel-ai-send-to-shell)
```

## Caveats

- The input, working directory, directory listing, recent terminal
  output and shell history leave the machine: the input goes to
  TypeSafe, everything to the gptel backend.
- Emacs blocks while a completion is pending.  Typing cancels the wait
  immediately; the reply is still cached for the next pause.
- Input routed to `shell`, `C-u RET` and `ghostel-ai-send-to-shell`
  skip the destructive check too.
- When the classifier is unreachable the input is sent unchanged.  Once
  it is classified as natural language it is never sent as typed by
  `RET`: a model failure keeps it in the input region.

## Development

`make` byte-compiles with warnings as errors, runs checkdoc and the
tests.  Load paths for ghostel and gptel default to
`~/.emacs.d/lib`; override with `make LIB=/path`.
