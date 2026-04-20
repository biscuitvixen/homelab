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
    const tableRows = ref([]);
    const showCertModal = ref(false);

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

    async function loadTable() {
      try {
        const res = await fetch("services-table.json", { cache: "no-cache" });
        tableRows.value = await res.json();
      } catch (error) {
        console.error('Error loading services table:', error);
      }
    }

    async function downloadCertificate() {
      try {
        const response = await fetch('skypaw.crt');
        if (!response.ok) {
          throw new Error('Certificate file not found');
        }
        
        const blob = await response.blob();
        const url = window.URL.createObjectURL(blob);
        
        const a = document.createElement('a');
        a.href = url;
        a.download = 'skypaw.crt';
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        
        // Clean up the blob URL
        window.URL.revokeObjectURL(url);
      } catch (error) {
        console.error('Error downloading certificate:', error);
        alert('Failed to download certificate. Please check if the file exists.');
      }
    }

    onMounted(() => {
      load();
      loadTable();
    });
    
    return { 
      links,
      tableRows,
      showCertModal,
      downloadCertificate 
    };
  }
}).mount("#app");