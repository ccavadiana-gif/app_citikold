/**
 * PUENTE Supabase → hoja del formulario «PORTEO TPG (Respuestas)»
 *
 * Hace lo mismo que el puente de Code.gs: cada viaje TPG finalizado en la app
 * se agrega como fila en «Respuestas de formulario 1» (columnas A a M, más N y O),
 * para que el dashboard siga leyendo la misma hoja. MUELLE → T2/T3/T4/R8 cuenta como 2 filas.
 *
 * Instalación (una sola vez):
 * 1. Abre la hoja del formulario → Extensiones → Apps Script → pega este archivo.
 * 2. Configuración del proyecto → Propiedades del script → agrega  PUENTE_PIN = (el PIN del acceso de rol «puente»).
 * 3. Ejecuta  instalar  una vez y acepta los permisos. Queda corriendo cada minuto.
 */
const SUPA_URL = 'https://enmeztklllzkvruiluxw.supabase.co/rest/v1/rpc/api';
const SUPA_KEY = 'sb_publishable_aHmjv34f0KsV9FzK2NxUIA_5fgQxzB1';
const FORM_TAB = 'Respuestas de formulario 1';
const TZ = 'America/Guayaquil';

function api_(fn, args) {
  const r = UrlFetchApp.fetch(SUPA_URL, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: SUPA_KEY }, payload: JSON.stringify({ fn: fn, args: args })
  });
  const j = JSON.parse(r.getContentText() || 'null');
  if (r.getResponseCode() !== 200) throw new Error((j && j.message) || ('HTTP ' + r.getResponseCode()));
  if (j && j.error !== undefined) throw new Error(j.error);
  return j ? j.ok : null;
}

function fTs_(ms) { return Utilities.formatDate(new Date(ms), TZ, 'd/M/yyyy H:mm:ss'); }
function fHr_(ms) {
  if (!ms) return '';
  const d = new Date(ms), h = Number(Utilities.formatDate(d, TZ, 'H'));
  return (h % 12 || 12) + ':' + Utilities.formatDate(d, TZ, 'mm:ss') + (h >= 12 ? ' p.m.' : ' a.m.');
}

/** Escribe una fila en la primera fila libre (busca la última con datos en la columna A) y comprueba que quedó escrita. */
function formAppend_(sh, fila) {
  const max = sh.getMaxRows(), from = Math.max(1, sh.getLastRow() - 60);
  const colA = sh.getRange(from, 1, max - from + 1, 1).getValues();
  let last = from - 1;
  for (let i = colA.length - 1; i >= 0; i--) { if (String(colA[i][0]).trim() !== '') { last = from + i; break; } }
  if (last < 1) last = 1;
  const r = last + 1;
  if (r > max) sh.insertRowsAfter(max, r - max);
  sh.getRange(r, 1, 1, 13).setValues([fila.slice(0, 13)]);
  sh.getRange(1, 14, 1, 2).setValues([['LLEGADA A CARGA', 'LLEGADA A DESCARGA']]);
  sh.getRange(r, 14, 1, 2).setValues([[fila[13] || '', fila[14] || '']]);
  SpreadsheetApp.flush();
  if (String(sh.getRange(r, 6).getValue()) !== String(fila[5])) throw new Error('No se pudo comprobar la escritura en la fila ' + r);
}

/** Corre cada minuto: trae los viajes pendientes y los pasa a la hoja. */
function puente() {
  const pin = PropertiesService.getScriptProperties().getProperty('PUENTE_PIN');
  if (!pin) throw new Error('Falta la propiedad PUENTE_PIN.');
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(5000)) return;
  try {
    const sh = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(FORM_TAB);
    if (!sh) throw new Error('No se encontró la pestaña ' + FORM_TAB);
    const pend = api_('api_puentePendientes', [pin, 30]) || [];
    pend.forEach(function (v) {
      try {
        const fila = [fTs_(v.t6), v.chofer, v.placa, v.turno, v.medida, v.contenedor, v.origen, v.destino,
          fHr_(v.t2), fHr_(v.t3), fHr_(v.t5), fHr_(v.t6), v.observaciones, fHr_(v.t1), fHr_(v.t4)];
        if (v.puente !== 'OK1') formAppend_(sh, fila);
        if (v.doble) {
          api_('api_puenteMarcar', [pin, v.id, 'OK1', '']);
          const f2 = fila.slice(); f2[0] = fTs_(v.t6 + 1000);   // 2.ª fila para el terminal; el chofer solo ve 1 viaje
          formAppend_(sh, f2);
        }
        api_('api_puenteMarcar', [pin, v.id, 'OK', '']);
      } catch (e) {
        try { api_('api_puenteMarcar', [pin, v.id, 'ERR', String(e && e.message ? e.message : e)]); } catch (e2) {}
      }
    });
  } finally { lock.releaseLock(); }
}

function instalar() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'puente') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('puente').timeBased().everyMinutes(1).create();
  puente();
}
