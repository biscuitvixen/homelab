const { createApp, ref, onMounted } = Vue;

function hostFromUrl(u) {
  try { 
    return new URL(u).host;
  } catch (error) { 
    return ""; 
  }
}

createApp({
  setup() {
    const links = ref([]);

    async function load() {
      try {
        const res = await fetch("services.json", { cache: "no-cache" });
        const items = await res.json();
        
        links.value = items.map(x => ({
          ...x, 
          host: hostFromUrl(x.href)
        }));
      } catch (error) {
        console.error('Error loading services:', error);
      }
    }

    function downloadCertificate() {
      const a = document.createElement('a');
      a.href = 'skypaw.crt';
      a.download = 'skypaw.crt';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
    }

    onMounted(() => {
      load();
    });
    
    return { 
      links,
      downloadCertificate 
    };
  }
}).mount("#app");