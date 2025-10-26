const { createApp, reactive, onMounted } = Vue;

function hostFromUrl(u) {
  try { 
    return new URL(u).host; 
  } catch { 
    return ""; 
  }
}

async function probe(url, ms = 2500) {
  // Best-effort: cross-origin HEAD with timeout; success => green
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    await fetch(url, { method: "HEAD", mode: "no-cors", signal: ctl.signal });
    clearTimeout(t);
    return "ok";
  } catch {
    clearTimeout(t);
    return "down";
  }
}

createApp({
  setup() {
    const state = reactive({ links: [] });

    async function load() {
      try {
        console.log("Loading services.json...");
        const res = await fetch("services.json", { cache: "no-cache" });
        console.log("Response status:", res.status);
        
        if (!res.ok) {
          throw new Error(`HTTP ${res.status}: ${res.statusText}`);
        }
        
        const items = await res.json();
        console.log("Loaded items:", items);
        
        state.links = items.map(x => ({
          ...x, 
          host: hostFromUrl(x.href)
        }));
        
        console.log("State links after mapping:", state.links);
        probeAll();
      } catch (error) {
        console.error("Failed to load services.json:", error);
        // Fallback data for testing
        state.links = [
          { name: "AdGuard", href: "https://adguard.lan", subtitle: "DNS & filtering", host: "adguard.lan", statusClass: "" },
          { name: "Home Assistant", href: "https://home.lan", subtitle: "Home automation", host: "home.lan", statusClass: "" },
          { name: "TrueNAS", href: "https://truenas.lan", subtitle: "Storage", host: "truenas.lan", statusClass: "" },
          { name: "Proxmox", href: "https://pve.lan", subtitle: "Virtualization", host: "pve.lan", statusClass: "" }
        ];
      }
    }

    async function probeAll() {
      for (const item of state.links) {
        item.statusClass = ""; // reset
        item.statusClass = await probe(item.href);
      }
    }

    onMounted(load);
    return { ...state, probeAll };
  }
}).mount("#app");