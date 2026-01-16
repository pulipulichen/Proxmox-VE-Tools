// --- State Management ---
const state = {
    detectedDomain: 'test.local',
    ouPaths: [], // Strings from textarea
    users: [],  // Specific users from Section 2
};

// --- DOM Elements ---
const el = {
    previewBaseDn: document.getElementById('previewBaseDn'),
    detectedDomainDisplay: document.getElementById('detectedDomainDisplay'),
    ouTextarea: document.getElementById('ouTextarea'),
    ouCountBadge: document.getElementById('ouCountBadge'),
    userContainer: document.getElementById('userContainer'),

    outFilterSingle: document.getElementById('outFilterSingle'),
    outGroupFilter: document.getElementById('outGroupFilter'), // NEW
    outFilterPretty: document.getElementById('outFilterPretty')
};

// --- Persistence ---
const STORAGE_KEY = 'ldap_pve_filter_state_v3'; // Changed key version

function saveToLocalStorage() {
    const dataToSave = {
        ouTextarea: el.ouTextarea.value,
        users: state.users
    };
    localStorage.setItem(STORAGE_KEY, JSON.stringify(dataToSave));
}

function loadFromLocalStorage() {
    const savedData = localStorage.getItem(STORAGE_KEY);
    if (savedData) {
        try {
            const parsed = JSON.parse(savedData);
            if (parsed.ouTextarea !== undefined) {
                el.ouTextarea.value = parsed.ouTextarea;
            }
            if (parsed.users) {
                state.users = parsed.users;
            }
            return true;
        } catch (e) {
            console.error("Failed to load from localStorage", e);
        }
    }
    return false;
}

// --- Initialization ---
function init() {
    const loaded = loadFromLocalStorage();
    
    // Default value for Textarea if nothing saved
    if (!loaded) {
        el.ouTextarea.value = "test.local/總部/資訊部\ntest.local/總部/財務部";
    }

    renderUserInputs();
    bindEvents();
    updateAll();
}

function bindEvents() {
    el.ouTextarea.addEventListener('input', () => {
        updateAll();
        saveToLocalStorage();
    });
}

// --- Logic: DN Conversion ---
function domainToDn(domain) {
    if (!domain) return '';
    return 'DC=' + domain.split('.').join(',DC=');
}

/**
 * Converts a path "domain/OU/OU/Group" into a Group DN.
 * Logic: Last segment is CN, middle segments are OUs.
 */
function pathToDn(path, domain) {
    if (!path) return '';
    let cleanPath = path.trim();
    if (!cleanPath) return '';

    // Standardize path
    let parts = cleanPath.split('/').filter(p => p.trim() !== '');

    // Logic: Remove domain from start if present
    if (parts.length > 0 && parts[0].toLowerCase() === domain.toLowerCase()) {
        parts.shift();
    }

    if (parts.length === 0) return '';

    // The LAST part is the Group Name (CN)
    const groupName = parts.pop(); 
    
    // The remaining parts are OUs, reversed (Bottom-up)
    let ouParts = parts.reverse().map(p => `OU=${p}`);

    // Construct DN: CN=Group,OU=...,DC=...
    const dnComponents = [`CN=${groupName}`, ...ouParts, domainToDn(domain)];
    
    return dnComponents.join(',');
}

// --- UI Rendering: Users (Section 2) ---
function renderUserInputs() {
    el.userContainer.innerHTML = '';
    if (state.users.length === 0) {
        el.userContainer.innerHTML = '<div class="text-xs text-slate-400 italic p-2 border border-dashed rounded">無特定帳號</div>';
    }
    state.users.forEach((usr, index) => {
        const div = document.createElement('div');
        div.className = 'flex gap-2 items-center';
        div.innerHTML = `
            <select onchange="updateUserType(${index}, this.value)" class="p-2 text-xs border rounded bg-slate-50 border-slate-300 w-28">
                <option value="sAMAccountName" ${usr.type === 'sAMAccountName' ? 'selected' : ''}>sAMAcc..</option>
                <option value="userPrincipalName" ${usr.type === 'userPrincipalName' ? 'selected' : ''}>UPN</option>
            </select>
            <input type="text" value="${usr.value}" oninput="updateUserValue(${index}, this.value)" 
                class="flex-1 p-2 text-sm border border-slate-300 rounded focus:ring-1 focus:ring-indigo-500 outline-none" placeholder="value">
            <button onclick="removeUser(${index})" class="text-red-400 hover:text-red-600 px-2 font-bold">&times;</button>
        `;
        el.userContainer.appendChild(div);
    });
}

function addUserRow() {
    state.users.push({ type: 'sAMAccountName', value: '' });
    renderUserInputs();
    updateAll();
    saveToLocalStorage();
}

function removeUser(index) {
    state.users.splice(index, 1);
    renderUserInputs();
    updateAll();
    saveToLocalStorage();
}

window.updateUserType = (index, type) => { 
    state.users[index].type = type; 
    updateAll(); 
    saveToLocalStorage();
};
window.updateUserValue = (index, val) => { 
    state.users[index].value = val; 
    updateAll(); 
    saveToLocalStorage();
};

// --- Logic: Main Generation ---
function updateAll() {
    const rawText = el.ouTextarea.value;
    state.ouPaths = rawText.split('\n').map(line => line.trim()).filter(line => line !== '');
    el.ouCountBadge.textContent = `${state.ouPaths.length} 筆路徑`;

    // 1. Detect Domain from first valid path
    let detectedDomain = 'example.com';
    if (state.ouPaths.length > 0) {
        const firstPath = state.ouPaths[0];
        const parts = firstPath.split('/');
        if (parts.length > 0 && parts[0].includes('.')) {
            detectedDomain = parts[0];
        }
    }
    state.detectedDomain = detectedDomain;
    el.detectedDomainDisplay.textContent = detectedDomain;
    el.previewBaseDn.textContent = domainToDn(detectedDomain);

    // 2. Build Conditions
    const userMemberOfConditions = []; // For User Filter
    const groupDnConditions = [];      // For Group Filter (PVE Sync)

    // Process Paths
    state.ouPaths.forEach(path => {
        const fullDn = pathToDn(path, detectedDomain);
        if (fullDn) {
            // User Filter needs: (memberOf=CN=...,OU=...)
            userMemberOfConditions.push(`(memberOf=${fullDn})`);
            
            // Group Filter needs: (distinguishedName=CN=...,OU=...)
            // This ensures we only sync the specific groups mentioned in the path
            groupDnConditions.push(`(distinguishedName=${fullDn})`);
        }
    });

    // Specific Users (Only affects User Filter)
    state.users.filter(u => u.value.trim()).forEach(u => {
        userMemberOfConditions.push(`(${u.type}=${u.value.trim()})`);
    });

    // 3. Assemble USER Filter (Login Permissions)
    const userObjectReq = `(objectCategory=person)(objectClass=user)`;
    let finalUserFilter = '';

    if (userMemberOfConditions.length === 0) {
        finalUserFilter = `(&${userObjectReq})`;
    } else {
        const orBlock = `(|${userMemberOfConditions.join('')})`;
        finalUserFilter = `(&${userObjectReq}${orBlock})`;
    }

    // 4. Assemble GROUP Filter (PVE Sync)
    // Needs (objectClass=group) AND ( DN=A OR DN=B ... )
    const groupObjectReq = `(objectClass=group)`;
    let finalGroupFilter = '';
    
    if (groupDnConditions.length === 0) {
        // If no groups defined, don't sync any groups (safer) or sync all (risky)
        // Here we default to (objectClass=group) which syncs ALL groups if list is empty, 
        // BUT usually it's better to return a "match nothing" if intent is empty.
        // Let's stick to base requirement.
        finalGroupFilter = `(${groupObjectReq})`; 
    } else {
        const groupOrBlock = `(|${groupDnConditions.join('')})`;
        finalGroupFilter = `(&${groupObjectReq}${groupOrBlock})`;
    }

    // 5. Outputs
    el.outFilterSingle.value = finalUserFilter;
    el.outGroupFilter.value = finalGroupFilter; // NEW Output
    el.outFilterPretty.textContent = formatLdapFilter(finalUserFilter);
}

function formatLdapFilter(filter) {
    let indent = 0;
    let output = '';
    for (let i = 0; i < filter.length; i++) {
        const char = filter[i];
        if (char === '(') {
            output += '\n' + '  '.repeat(indent) + char;
            indent++;
        } else if (char === ')') {
            indent--;
            output += char;
        } else {
            output += char;
        }
    }
    return output.trim();
}

// --- Helpers ---
window.addUserRow = addUserRow;
window.removeUser = removeUser;

window.copyToClipboard = (id) => {
    const el = document.getElementById(id);
    el.select();
    document.execCommand('copy');
};

// Start
init();