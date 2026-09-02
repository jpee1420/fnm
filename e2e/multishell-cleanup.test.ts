import { script } from "./shellcode/script.js"
import { Bash, Fish, PowerShell, Zsh } from "./shellcode/shells.js"
import testCwd from "./shellcode/test-cwd.js"
import fs from "node:fs/promises"
import path from "node:path"
import describe from "./describe.js"

for (const shell of [Bash, Zsh, Fish, PowerShell]) {
  describe(shell, () => {
    test("multishell is cleaned up after subshell exits", async () => {
      await fs.writeFile(
        path.join(testCwd(), "record.cjs"),
        `const fs = require('fs'); fs.writeFileSync('subshell-multishell.txt', process.env.FNM_MULTISHELL_PATH || '');`
      )
      await fs.writeFile(
        path.join(testCwd(), "verify.cjs"),
        `const fs = require('fs');
const msPath = fs.readFileSync('subshell-multishell.txt', 'utf8').trim();
if (!msPath) { console.log('NO_PATH'); process.exit(1); }
if (fs.existsSync(msPath)) { console.log('STILL_EXISTS'); process.exit(1); }
console.log('CLEANED_UP');`
      )

      await script(shell)
        .then(shell.env({}))
        .then(shell.call("fnm", ["install", "v11.9.0"]))
        .then(shell.call("fnm", ["use", "v11.9.0"]))
        .then(
          shell.inSubShell(
            script(shell)
              .then(shell.env({}))
              .then(shell.call("node", ["record.cjs"]))
              .asLine()
          )
        )
        .then(
          shell.hasCommandOutput(
            shell.call("node", ["verify.cjs"]),
            "CLEANED_UP",
            "multishell directory to be cleaned up on exit"
          )
        )
        .takeSnapshot(shell)
        .execute(shell)
    })
  })
}
