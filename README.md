# Scrieopta

Saber Simulator scripts (Roblox / Luau).

## Load with loadstring()

Auto-Swing + Auto-Sell + Auto-Buy Saber:
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/saber_autofarm_option1.lua"))()
```

Buy Best Saber only:
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/saber_buy_best.lua"))()
```

## Files

- `saber_autofarm_option1.lua` - Auto-Swing (`SwingSaber`) + Auto-Sell (`SellStrength`) + Auto-Buy Saber. Click START or press F to toggle.
- `saber_buy_best.lua` - Standalone: every 5s buys the best saber you can afford that is better than your current one.
- `saber_buy_debug.lua` - Diagnostic: prints leaderstats, Swords data, UpdateClientData fields, and tests a manual buy.

## Confirmed by RemoteSpy

```lua
game:GetService("ReplicatedStorage").Events.UIAction:FireServer("BuyWeapon", "Daze")
```

Buying uses `UIAction` with action `"BuyWeapon"` and the saber name as the second argument, not `"BuySword"`.
