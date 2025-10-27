const { createApp, ref, onMounted } = Vue;

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
    return "ok";
  } catch {
    return "down";
  } finally {
    clearTimeout(t);
  }
}

createApp({
  setup() {
    const links = ref([]);
    const lastChecked = ref("");

    async function load() {
      try {
        const res = await fetch("services.json", { cache: "no-cache" });
        const items = await res.json();
        links.value = items.map(x => ({
          ...x,
          host: hostFromUrl(x.href),
          statusClass: "loading"        // start in loading state
        }));
        probeAll();
      } catch (e) {
        console.error("Failed to load services.json:", e);
        links.value = [
          { name:"AdGuard", href:"https://adguard.lan",  subtitle:"DNS & filtering", host:"adguard.lan",  statusClass:"loading" },
          { name:"Home Assistant", href:"https://home.lan", subtitle:"Home automation", host:"home.lan", statusClass:"loading" },
          { name:"TrueNAS", href:"https://truenas.lan", subtitle:"Storage", host:"truenas.lan", statusClass:"loading" },
          { name:"Proxmox", href:"https://pve.lan", subtitle:"Virtualization", host:"pve.lan", statusClass:"loading" },
        ];
        probeAll();
      }
    }

    async function probeAll() {
      // show spinner while checking
      for (const item of links.value) item.statusClass = "loading";

      // probe sequentially (simple & avoids flooding); switch to Promise.all if you want parallel
      for (const item of links.value) {
        item.statusClass = await probe(item.href);  // "ok" or "down"
      }
      lastChecked.value = new Date().toLocaleTimeString();
    }

    onMounted(load);
    return { links, lastChecked, probeAll };
  }
}).mount("#app");