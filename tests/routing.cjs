// Where a card click lands. Executes the production routing functions from
// Service.qml against a desktop shaped like a real one: two terminals, a
// browser, a Quickshell app and an Electron app.
const assert=require('node:assert/strict'), fs=require('node:fs'), vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/../Service.qml','utf8');
const fn=name=>source.match(new RegExp('function '+name+'\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}'))[0];
const prop=name=>source.match(new RegExp('property var '+name+':\\s*([\\s\\S]*?)\\n\\n'))[1];

const windows=[
 {wmClass:'com.mitchellh.ghostty',title:'gemini',address:'0x1',pid:10,focusOrder:3},
 {wmClass:'zen',title:'Claude pricing — Zen Browser',address:'0x2',pid:11,focusOrder:1},
 {wmClass:'org.quickshell',title:'Pear Messages',address:'0x3',pid:12,focusOrder:4},
 {wmClass:'com.anthropic.Claude',title:'Claude',address:'0x4',pid:13,focusOrder:2},
 {wmClass:'com.mitchellh.ghostty',title:'Notification routing',address:'0x5',pid:14,focusOrder:0},
];
const scope={smartRaise:true,openWindows:()=>windows};
vm.createContext(scope);
vm.runInContext('var browserClasses='+source.match(/browserClasses: (\/.*\/)\n/)[1]+';'
 +'var browserSuffix='+prop('browserSuffix')+';var genericLabels='+prop('genericLabels')+';',scope);
for (const name of ['wordIn','brandsOf','mostRecent','windowForPid','windowForSource','windowFor'])
 vm.runInContext(fn(name),scope);
const at=row=>(scope.windowFor(row)||{}).address;

// The sender's own window wins.
assert.equal(at({senderPid:10,source:'Claude'}),'0x1');
// A notify-send that has already exited: the app name has to find it.
assert.equal(at({senderPid:999,source:'Pear Messages'}),'0x3');    // Quickshell app, by title
assert.equal(at({senderPid:999,source:'Claude'}),'0x4');           // reverse-DNS class
// No app name, only the terminal's icon: the terminal used last.
assert.equal(at({senderPid:0,source:'',appIcon:'com.mitchellh.ghostty'}),'0x5');
// A browser tab titled "Claude ..." is not the Claude app, and an icon that
// is a theme name rather than a class finds nothing.
windows.splice(3,1);
assert.equal(at({senderPid:0,source:'Claude'}),undefined);
assert.equal(at({senderPid:0,source:'',appIcon:'battery-caution'}),undefined);
console.log('routing: ok');
