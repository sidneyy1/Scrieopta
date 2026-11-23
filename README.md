# Scrieopta

One loadstring for every game. The router checks which game you are in and runs only that game's script.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/router.lua"))()
```

## Games

### Saber Simulator

See [`Saber Simulator/`](Saber%20Simulator/) — Auto-Swing + Auto-Sell + Auto-Buy Saber + Auto-Buy DNA for Saber Simulator.

### Throw Food For Animals

See [`Throw Food For Animals/`](Throw%20Food%20For%20Animals/) — Auto perfect throw + Auto Equip Best + Auto Upgrade Base/Bar for Throw Food For Animals.

Direct loadstring (no router):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/Throw%20Food%20For%20Animals/throw_food_auto.lua"))()
```

Remote probe (tests which server remotes accept forged values, results on screen):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/Throw%20Food%20For%20Animals/probe_food_remotes.lua"))()
```

Direct loadstring (no router):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/Saber%20Simulator/saber_autofarm_option1.lua"))()
```
