// All untrusted values are assigned through textContent or URLSearchParams.
export function accountPage(publishableKey: string, clerkScriptURL: string, nonce: string) {
  const encoded = JSON.stringify({ publishableKey, clerkScriptURL }).replace(/</g, "\\u003c");
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Connect Ghostie</title><style nonce="${nonce}">
body{font:16px/1.55 system-ui;background:#f7f6ef;color:#18352d;margin:0;padding:48px 20px}main{max-width:520px;margin:auto}h1{font-size:32px}button,input{font:inherit;padding:12px;border:1px solid #647a6b;border-radius:8px;margin:8px 8px 8px 0}button{cursor:pointer;background:#d4f5dc}button:disabled{opacity:.5}input{display:block;width:85%}small{display:block;color:#53675c}#status{white-space:pre-wrap}a{color:inherit}
</style><main><h1 id="heading">Connect your Mac</h1><p id="intro">Read iMessage and WhatsApp, stage drafts for review, and create mobile Messages compose links.</p>
<div id="login"></div><button id="signup" hidden>Create an account</button><div id="account" hidden>
<p id="identity"></p><div id="connection"><p id="details"></p><label id="code-label" hidden>Code shown in Ghostie on your Mac<input id="code" autocomplete="off" maxlength="8" spellcheck="false"></label>
<p>Message reads and staged drafts pass through Ghostie's relay in memory. Compose links store the recipient and message body as encrypted ciphertext for seven days. Anyone with a compose link can use it until it expires.</p>
<p>HTTPS encrypts the connection. Suspected authentication codes are filtered on your Mac, but filtering cannot catch every format.</p>
<p>The Mac must stay awake with Ghostie hosting. Remote access cannot send or approve messages.</p>
<button id="approve" disabled>Connect</button><button id="cancel">Cancel</button></div><button id="manage">Manage account</button><button id="signout">Sign out</button></div><p id="status" role="status" aria-live="polite">Loading secure sign-in...</p></main>
<script nonce="${nonce}">
const config=${encoded};
const byID=id=>document.getElementById(id);
const query=Object.fromEntries(new URLSearchParams(location.search));
const returnURL=location.pathname+location.search;
const pairing=location.pathname==='/pair';
const accountOnly=location.pathname==='/account';
if(accountOnly){byID('heading').textContent='Your Ghostie account';byID('intro').textContent='Sign in with your email, then manage your account or add an optional passkey.';byID('connection').hidden=true;}
const status=message=>byID('status').textContent=message;
const api=async(path,body)=>{
 const token=await window.Clerk.session.getToken();
 const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},body:JSON.stringify(body)});
 const data=await response.json(); if(!response.ok)throw Error('This request is unavailable or has expired. Start again in Ghostie or your MCP client.');return data;
};
let signInMounted=false;
async function render(){
 if(!window.Clerk.user){byID('account').hidden=true;byID('signup').hidden=false;if(!signInMounted){window.Clerk.mountSignIn(byID('login'),{routing:'hash',forceRedirectUrl:returnURL,signUpForceRedirectUrl:returnURL});signInMounted=true;}status('Sign in or create an account to continue.');return;}
 if(signInMounted){window.Clerk.unmountSignIn(byID('login'));signInMounted=false;}byID('signup').hidden=true;byID('account').hidden=false;
 byID('identity').textContent='Signed in as '+(window.Clerk.user.primaryEmailAddress?.emailAddress||window.Clerk.user.id);
 if(accountOnly){status('Choose Manage account, then Security to add a passkey.');return;}
 try{
  if(pairing){byID('code-label').hidden=false;byID('details').textContent='Only connect if you started this from Ghostie on your own Mac. Enter the code displayed there.';}
  else{const data=await api('/api/consent/details',query);const link=typeof data.scope==='string'&&data.scope.split(' ').includes('messages:link');byID('details').textContent='Allow '+data.client+' ('+data.redirect_origin+') to '+(data.permissions||'read messages and stage drafts')+' on this Mac'+(link?'. Compose links are public seven-day compose links containing a recipient and message body; a link opens a prefilled compose screen but never sends':'')+': '+data.host;}
  byID('approve').disabled=false;status('Review the access above, then choose Connect.');
 }catch(e){status(e.message);}
}
byID('approve').onclick=async()=>{if(accountOnly)return;byID('approve').disabled=true;try{
 if(pairing){await api('/api/pair/approve',{id:query.id,code:byID('code').value.trim().toUpperCase()});status('Account connected. Return to Ghostie to start hosting.');byID('account').hidden=true;}
 else{const data=await api('/api/consent/approve',query);location.assign(data.redirect);}
}catch(e){status(e.message);byID('approve').disabled=false;}};
byID('cancel').onclick=()=>{byID('account').hidden=true;status('Cancelled. No new access was granted. You can close this window.');};
byID('signout').onclick=()=>window.Clerk.signOut({redirectUrl:'/account'});
byID('manage').onclick=()=>{if(window.Clerk.user)window.Clerk.openUserProfile();};
byID('signup').onclick=()=>window.Clerk.openSignUp({forceRedirectUrl:returnURL,signInForceRedirectUrl:returnURL});
const script=document.createElement('script');script.src=config.clerkScriptURL;script.dataset.clerkPublishableKey=config.publishableKey;script.crossOrigin='anonymous';
script.onload=async()=>{try{await window.Clerk.load();await render();window.Clerk.addListener(()=>render());}catch{status('Sign-in is unavailable. Try again later.');}};
script.onerror=()=>status('Sign-in could not load. Try again later.');document.head.appendChild(script);
</script></html>`;
}
