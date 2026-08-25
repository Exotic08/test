package dev.exotic08.noriptidecooldown;

import org.bukkit.ChatColor;
import org.bukkit.Material;
import org.bukkit.command.Command;
import org.bukkit.command.CommandExecutor;
import org.bukkit.command.CommandSender;
import org.bukkit.command.PluginCommand;
import org.bukkit.command.TabCompleter;
import org.bukkit.enchantments.Enchantment;
import org.bukkit.entity.HumanEntity;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerRiptideEvent;
import org.bukkit.inventory.ItemStack;
import org.bukkit.plugin.java.JavaPlugin;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;
import java.util.logging.Level;

public final class NoRiptideCooldownPlugin extends JavaPlugin implements Listener, CommandExecutor, TabCompleter {
    private static final String PREFIX = ChatColor.AQUA + "[NoRiptideCooldown] " + ChatColor.GRAY;

    private int cooldownTicks;
    private boolean onlyRiptideEnchantedTridents;
    private boolean tryItemStackCooldownApi;
    private boolean debug;
    private List<Integer> applyDelaysTicks;

    /**
     * Vanilla Riptide also puts the player into a short auto-spin/riptiding state.
     * On many server versions that state is the practical "recast lock", not an item cooldown overlay.
     * -1 disables changing it; 0 clears it as soon as possible.
     */
    private int riptideSpinDurationTicks;
    private float riptideSpinAttackStrength;
    private List<Integer> riptideSpinApplyDelaysTicks;

    private Method setItemStackCooldownMethod;
    private Method startRiptideAttackMethod;
    private boolean warnedMissingStartRiptideAttackApi;

    @Override
    public void onEnable() {
        saveDefaultConfig();
        loadSettings();

        getServer().getPluginManager().registerEvents(this, this);

        PluginCommand command = getCommand("noriptidecooldown");
        if (command != null) {
            command.setExecutor(this);
            command.setTabCompleter(this);
        }

        getLogger().info("Enabled. Riptide cooldown target: " + cooldownTicks + " tick(s). Cooldown delays: " + applyDelaysTicks
                + ". Spin duration target: " + (riptideSpinDurationTicks < 0 ? "disabled" : riptideSpinDurationTicks + " tick(s)") + ".");
    }

    @EventHandler(priority = EventPriority.MONITOR, ignoreCancelled = true)
    public void onPlayerRiptide(PlayerRiptideEvent event) {
        ItemStack riptideItem = event.getItem();

        if (onlyRiptideEnchantedTridents && !isRiptideTrident(riptideItem)) {
            return;
        }

        Player player = event.getPlayer();
        ItemStack cooldownItem = riptideItem.clone();

        scheduleItemCooldown(player, cooldownItem);
        scheduleRiptideSpinDuration(player, cooldownItem);
    }

    private void scheduleItemCooldown(Player player, ItemStack cooldownItem) {
        for (int delay : applyDelaysTicks) {
            int remainingTicks = Math.max(0, cooldownTicks - delay);
            if (delay <= 0) {
                applyCooldown(player, cooldownItem, remainingTicks, delay);
            } else {
                getServer().getScheduler().runTaskLater(this, () -> applyCooldown(player, cooldownItem, remainingTicks, delay), delay);
            }
        }
    }

    private void scheduleRiptideSpinDuration(Player player, ItemStack cooldownItem) {
        if (riptideSpinDurationTicks < 0) {
            return;
        }

        for (int delay : riptideSpinApplyDelaysTicks) {
            int remainingTicks = Math.max(0, riptideSpinDurationTicks - delay);
            if (delay <= 0) {
                applyRiptideSpinDuration(player, cooldownItem, remainingTicks, delay);
            } else {
                getServer().getScheduler().runTaskLater(this,
                        () -> applyRiptideSpinDuration(player, cooldownItem, remainingTicks, delay), delay);
            }
        }
    }

    private boolean isRiptideTrident(ItemStack item) {
        return item != null
                && item.getType() == Material.TRIDENT
                && item.getEnchantmentLevel(Enchantment.RIPTIDE) > 0;
    }

    private void applyCooldown(Player player, ItemStack item, int ticks, int delay) {
        if (!player.isOnline()) {
            return;
        }

        boolean appliedItemStackCooldown = false;
        if (tryItemStackCooldownApi && setItemStackCooldownMethod != null && item != null) {
            try {
                setItemStackCooldownMethod.invoke(player, item, ticks);
                appliedItemStackCooldown = true;
            } catch (IllegalAccessException | InvocationTargetException exception) {
                getLogger().log(Level.WARNING, "Could not apply ItemStack cooldown API; falling back to Material.TRIDENT.", exception);
                setItemStackCooldownMethod = null;
            }
        }

        player.setCooldown(Material.TRIDENT, ticks);

        if (debug) {
            getLogger().info("Set Riptide item cooldown for " + player.getName()
                    + " to " + ticks + " tick(s) after delay " + delay
                    + " tick(s). itemStackApi=" + appliedItemStackCooldown);
        }
    }

    private void applyRiptideSpinDuration(Player player, ItemStack item, int ticks, int delay) {
        if (!player.isOnline()) {
            return;
        }

        if (startRiptideAttackMethod == null) {
            if (!warnedMissingStartRiptideAttackApi) {
                getLogger().warning("This server API does not expose HumanEntity#startRiptideAttack(int, float, ItemStack). "
                        + "Item cooldown reset still works, but the Riptide spin/recast lock cannot be shortened by this plugin on this API.");
                warnedMissingStartRiptideAttackApi = true;
            }
            return;
        }

        try {
            startRiptideAttackMethod.invoke(player, ticks, riptideSpinAttackStrength, item);
        } catch (IllegalAccessException | InvocationTargetException exception) {
            getLogger().log(Level.WARNING, "Could not apply Riptide spin duration; disabling spin-duration override.", exception);
            startRiptideAttackMethod = null;
        }

        if (debug) {
            getLogger().info("Set Riptide spin duration for " + player.getName()
                    + " to " + ticks + " tick(s) after delay " + delay + " tick(s).");
        }
    }

    private void loadSettings() {
        cooldownTicks = Math.max(0, getConfig().getInt("cooldown-ticks", 0));
        onlyRiptideEnchantedTridents = getConfig().getBoolean("only-riptide-enchanted-tridents", true);
        tryItemStackCooldownApi = getConfig().getBoolean("try-itemstack-cooldown-api", true);
        debug = getConfig().getBoolean("debug", false);
        applyDelaysTicks = readDelays("apply-delays-ticks", Arrays.asList(0, 1, 2, 5));

        riptideSpinDurationTicks = getConfig().getInt("riptide-spin-duration-ticks", 0);
        if (riptideSpinDurationTicks < 0) {
            riptideSpinDurationTicks = -1;
        }
        riptideSpinAttackStrength = (float) Math.max(0.0D, getConfig().getDouble("riptide-spin-attack-strength", 8.0D));
        riptideSpinApplyDelaysTicks = readDelays("riptide-spin-apply-delays-ticks", Arrays.asList(1, 2));

        setItemStackCooldownMethod = findSetItemStackCooldownMethod();
        startRiptideAttackMethod = findStartRiptideAttackMethod();
        warnedMissingStartRiptideAttackApi = false;
    }

    private List<Integer> readDelays(String path, List<Integer> defaultDelays) {
        TreeSet<Integer> delays = new TreeSet<>();

        for (Object value : getConfig().getList(path, defaultDelays)) {
            Integer delay = parseNonNegativeInteger(value);
            if (delay != null) {
                delays.add(delay);
            }
        }

        if (delays.isEmpty()) {
            delays.add(0);
        }

        return Collections.unmodifiableList(new ArrayList<>(delays));
    }

    private Integer parseNonNegativeInteger(Object value) {
        if (value instanceof Number) {
            return Math.max(0, ((Number) value).intValue());
        }

        if (value instanceof String) {
            try {
                return Math.max(0, Integer.parseInt((String) value));
            } catch (NumberFormatException ignored) {
                return null;
            }
        }

        return null;
    }

    private Method findSetItemStackCooldownMethod() {
        if (!tryItemStackCooldownApi) {
            return null;
        }

        try {
            return HumanEntity.class.getMethod("setCooldown", ItemStack.class, int.class);
        } catch (NoSuchMethodException exception) {
            return null;
        }
    }

    private Method findStartRiptideAttackMethod() {
        try {
            return HumanEntity.class.getMethod("startRiptideAttack", int.class, float.class, ItemStack.class);
        } catch (NoSuchMethodException exception) {
            return null;
        }
    }

    @Override
    public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        if (args.length == 0 || args[0].equalsIgnoreCase("status")) {
            sendStatus(sender);
            return true;
        }

        if (args[0].equalsIgnoreCase("reload")) {
            reloadConfig();
            loadSettings();
            sender.sendMessage(PREFIX + "Đã reload config. Cooldown Riptide: " + cooldownTicks + " tick(s).");
            return true;
        }

        if (args[0].equalsIgnoreCase("set")) {
            if (args.length < 2) {
                sender.sendMessage(PREFIX + ChatColor.RED + "Dùng: /" + label + " set <ticks>");
                return true;
            }

            Integer newCooldownTicks = parseNonNegativeInteger(args[1]);
            if (newCooldownTicks == null) {
                sender.sendMessage(PREFIX + ChatColor.RED + "Ticks phải là số nguyên >= 0.");
                return true;
            }

            getConfig().set("cooldown-ticks", newCooldownTicks);
            saveConfig();
            loadSettings();
            sender.sendMessage(PREFIX + "Đã set item cooldown Riptide thành " + cooldownTicks + " tick(s). 0 = không hồi chiêu.");
            return true;
        }

        sender.sendMessage(PREFIX + ChatColor.RED + "Lệnh không đúng. Dùng: /" + label + " [status|reload|set <ticks>]");
        return true;
    }

    private void sendStatus(CommandSender sender) {
        sender.sendMessage(PREFIX + "Item cooldown Riptide hiện tại: " + cooldownTicks + " tick(s). 0 = không hồi chiêu.");
        sender.sendMessage(PREFIX + "Item cooldown apply delays: " + applyDelaysTicks + ". Chỉ Riptide trident: " + onlyRiptideEnchantedTridents + ".");
        sender.sendMessage(PREFIX + "ItemStack cooldown API: " + (setItemStackCooldownMethod != null ? "available" : "not available/fallback") + ".");
        sender.sendMessage(PREFIX + "Riptide spin/recast lock: "
                + (riptideSpinDurationTicks < 0 ? "disabled" : riptideSpinDurationTicks + " tick(s), delays " + riptideSpinApplyDelaysTicks)
                + ", API: " + (startRiptideAttackMethod != null ? "available" : "not available") + ".");
    }

    @Override
    public List<String> onTabComplete(CommandSender sender, Command command, String alias, String[] args) {
        if (args.length == 1) {
            String prefix = args[0].toLowerCase(Locale.ROOT);
            List<String> options = Arrays.asList("status", "reload", "set");
            List<String> matches = new ArrayList<>();
            for (String option : options) {
                if (option.startsWith(prefix)) {
                    matches.add(option);
                }
            }
            return matches;
        }

        if (args.length == 2 && args[0].equalsIgnoreCase("set")) {
            return Arrays.asList("0", "1", "5", "10", "20");
        }

        return Collections.emptyList();
    }
}
