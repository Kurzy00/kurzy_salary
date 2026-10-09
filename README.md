# kurzy_salary

Configurable online salary for RedM servers running RSG Core. Earn funds while a character is online, then receive them automatically or collect them through a command, exported menu or server integration. Player-facing messages are in Polish.

## Features

- Job and grade rates, a fallback rate and optional duty requirement.
- Uncollected balance cap and lifetime accrual limits for citizens/outlaws.
- Server-owned session timers, including players online during a resource restart.
- Shared payout locks, request cooldowns and conditional database updates.
- Session checks after database waits and additive refunds when payment is rejected.
- No client-supplied amounts, jobs, account names or character identifiers.

## Requirements

- RedM FXServer with Lua 5.4 support.
- `rsg-core`, `ox_lib`, `oxmysql`.
- A `players` table containing `citizenid` and `outlawstatus`.

## Installation

1. Copy this folder into your resources directory as `kurzy_salary`.
2. Import `db.sql` into the server database.
3. Configure `config.lua`.
4. Start dependencies before the resource:

```cfg
ensure oxmysql
ensure ox_lib
ensure rsg-core
ensure kurzy_salary
```

The manifest declares all three dependencies. When a resource group also includes `kurzy_banking`, explicitly ensure `kurzy_salary` before that group so the bank sees an existing accrual owner.

For an older `salary` table without `count`, run this migration **once**, after checking the column does not already exist:

```sql
ALTER TABLE salary ADD COLUMN `count` INT UNSIGNED NOT NULL DEFAULT 0;
```

No schema changes are required when upgrading from a version that already has `count`. Existing balances and counts are preserved. Replace the Lua files and merge the new configuration options, then restart the resource.

## Configuration

All settings are in `config.lua`. Timing values use **milliseconds**; amounts use dollars and are rounded to cents.

| Setting | Default | Meaning |
| --- | --- | --- |
| `DevMode` | `false` | Debug logs |
| `Notify` | `true` | Accrual and collection notifications |
| `AutoCollect` | `true` | Automatically pay pending salary on every timer check |
| `CollectCommand.Enabled` | `true` | Register the collection command |
| `CollectCommand.Name` | `collect` | Command name without slash |
| `CollectCommand.Permission` | `user` | RSG permission; `user` allows all players |
| `PayoutAccount` | `'cash'` | RSG money account credited by automatic/menu/command payouts |
| `PayoutInterval` | `60000` | Time between accruals; currently one minute |
| `CheckInterval` | `60000` | Timer polling interval |
| `CollectCooldown` | `5000` | Shared menu/command/export cooldown |
| `BalanceCooldown` | `2000` | Balance request cooldown |
| `PayoutPerInterval` | `12.50` | Fallback for unlisted jobs or grades |
| `Cap` | `50.00` | Uncollected balance cap; `0` disables it |
| `RequireDuty` | `false` | Require `job.onduty` to accrue |
| `Jobs` | `{}` | Job/grade overrides |
| `CountCaps.Citizen` | `0` | Lifetime citizen accrual limit; `0` disables it |
| `CountCaps.Outlaw` | `0` | Lifetime outlaw accrual limit; `0` disables it |
| `OutlawStatusThreshold` | `100` | Outlaw threshold in `players.outlawstatus` |

The configured rate is **$12.50 per minute, with a $50 uncollected balance cap**. Automatic collection is enabled, so successfully paid funds no longer count toward that waiting-balance cap. For a 30-minute interval, set `PayoutInterval = 30 * 60 * 1000`. Use a check interval no longer than the payout interval. Debug mode is disabled by default.

### Job rates

Use exact names from your RSG jobs configuration and numeric or string grade keys:

```lua
Config.Jobs = {
    unemployed = { [0] = 12.50 },
    vallaw = {
        [0] = 12.50,
        [1] = 15.00,
        [2] = 20.00,
    },
}
```

An unlisted job or grade uses `PayoutPerInterval`. A rate of `0` disables salary for that grade. Rates and duty are checked when the interval is processed. This salary is separate from any built-in RSG job paycheck; configure your server accordingly.

`PayoutPerInterval` is the single fallback setting; the old optional `DefaultPayoutPerInterval` setting has been removed. Migrate its value into `PayoutPerInterval` if you used it.

### Caps and sessions

Collection clears only `hourlyBalance`. The lifetime `count` does not reset. A partial top-up to the balance cap counts as one accrual; a full balance does not increase the count. Citizen/outlaw categories share the same count, so changing status does not reset eligibility.

Timers begin when the server loads a character and stop on unload/disconnect. Restarting this resource begins a fresh interval for already-online characters. Partial intervals are not persisted; offline time and intervals missed while capped/ineligible do not accumulate. SQL conflicts are retried on the next check without consuming the pending interval.

## Collection modes

By default, `/collect` is available to every player and immediately credits their waiting salary to `PayoutAccount`. It does not require debug mode. Customize or disable it through `CollectCommand`.

`AutoCollect = true` pays the entire pending balance on each `CheckInterval`, after any due accrual. This also collects balances saved before enabling the option. Rejected payments remain pending and are retried on a later check, even when no new salary is due. Existing duty and lifetime caps still govern earning; they do not prevent collection of previously earned funds.

Set `AutoCollect = false` for manual collection only. Both modes can coexist and use the same lock, session validation and collection cooldown as the menu/export. A recent manual request can postpone automatic collection until the next check. The server export retains its original claim-only behavior.

```lua
Config.AutoCollect = true
Config.PayoutAccount = 'cash' -- Or another configured RSG account.
Config.CollectCommand = {
    Enabled = true,
    Name = 'collect',
    Permission = 'user',
}
```

Automatic payment goes directly to the RSG account and does not apply the separate bank resource's collection fee. Disable automatic collection and the command if your intended flow requires visiting the bank; existing menu/export integrations must follow that same rule.

## Integration

### Client menu

Call this from your NPC, target or menu:

```lua
exports['kurzy_salary']:OpenSalaryMenu()
```

Collection is available anywhere this export is used. There is no built-in bank location restriction. The server computes the amount and account itself. No client timer events are needed.

### Server export

```lua
local amount = exports['kurzy_salary']:collectPayout(source)
```

This legacy export atomically claims the waiting funds and returns the amount, or `0` on rejection. It **does not credit a wallet**. The calling server resource must deliver the money, verify the recipient session after any asynchronous work, and handle recovery if delivery fails. Prefer the built-in menu when you do not need a custom payout integration.

Never pay an amount fetched by `getBalance`; that callback is for display only. Other resources modifying `salary` must use conditional claims and additive refunds, not unconditional zeroing.

### kurzy_banking

The local `kurzy_banking` resource uses the same `salary` table and its own conditional collection operation. This resource's conditional claims prevent both paths from collecting the same unchanged balance. Bank payout accounts/fees are controlled by the bank's configuration.

Use only one accrual owner. In the local bank implementation, ownership is checked once at startup: start `kurzy_salary` **before** `kurzy_banking`, or disable the bank's salary accrual separately. If changing ownership while the server is running, restart the bank after arranging the intended owner. Starting both through a resource group alone does not document an explicit order. The local server config explicitly ensures `kurzy_salary` before the custom resource group; bank code is unchanged.

## Failure handling

The normal `AddMoney == false` path restores the claimed amount to the original character without overwriting new accruals. A changed/disconnected session is treated the same way. Invalid payout account configuration stops initialization.

RSG wallet changes and SQL balance claims are not a single durable transaction. A process crash between them, a failed refund query, or an exception inside `AddMoney` requires reconciliation from server logs and balances. An exception may occur after the wallet was changed, so the resource logs the character/amount and does not automatically refund an ambiguous result. It does not promise exactly-once delivery across server crashes.

## Testing

Run the deterministic mock suite with Lua 5.4 from the resource directory:

```sh
lua tests/server_spec.lua
```

It checks duplicate requests, cross-resource claim conflicts, concurrent accrual, character switches/source reuse, refunds, SQL failures, restart initialization, rates, caps and cooldowns. It does not connect to a real database.

Before deployment, verify on a test server:

1. Load a character and wait for one configured interval.
2. Collect through `OpenSalaryMenu`; confirm wallet, balance and persistent count.
3. Test a configured job/grade, off-duty behavior and both count caps.
4. Restart the resource while online and confirm accrual resumes after a fresh interval.
5. If using a bank, verify startup ownership and simultaneous menu/bank collection.
6. Test `/collect` with `DevMode = false`, custom command permissions, and automatic payment to the configured account. Disable `AutoCollect` to test manual-only collection.


