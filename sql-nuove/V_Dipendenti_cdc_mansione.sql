-- =============================================================
-- V_Dipendenti: il CDC si compone dal codice della filiale piu' quello della
-- mansione (SIST_TIPI, IdPadre=3). La join cercava la descrizione esatta, ma
-- sulla scheda la mansione porta spesso davanti la zona ("Cagliari - DRIVER"),
-- quindi non trovava nulla e il CDC usciva con la sola filiale.
-- Ora si aggancia la parte dopo l'ultimo " - ".
-- =============================================================
ALTER VIEW [dbo].[V_Dipendenti]
AS
select
  u.IdUtente 

  ,u.Nome 
  ,u.CodiceFiscale 
  ,convert(int,u.Matricola) Matricola 
  ,u.Livello
  ,u.Mansione
  ,isnull(f.CodZUK,'')+isnull(mans.Valore,'') as CDC
  ,isnull(u.Partime,0) as Partime 
  ,f.Filiale 
  ,u.GiorniLavorativi
  ,u.OrarioLavoro

  ,case when isnull(u.datafine,'291231')<GETDATE() then 'Dimesso' else 'Attivo' end as Attivo
  ,u.Stato
  ,u.DataNascita 
  ,convert(date,u.DataInizio) as DataInizio 
  ,convert(date,u.DataFine) as DataFine
  ,u.Email 
  ,u.telefono  
  ,u.Iban
  ,u.TagliaAbbigliamento
  ,u.NumeroScarpe
  ,u.Note
  ,u.IndirizzoRes 
  ,u.CapRes 
  ,u.ComuneRes
  ,u.ProvRes
  ,case when isnull(u.datafine,'291231')<GETDATE() then '#FBCEB1' --rosso
	--when sa.Stato in ('24') then '#FFFFE0'
	--when sa.Stato in ('25') then '#BAFFBB'
	--else '#FFFDC9' 
	else '' end as COLOR#

from
  UTENTI u
  left join RUOLI r on r.IdRuolo=u.idruolo
  inner join FILIALI f on f.IDFILIALE=u.idfiliale
  -- La mansione sulla scheda spesso ha davanti la zona ("Hub POPUP - ADDETTO
  -- SMISTAMENTO/LINEE"), mentre in SIST_TIPI c'e' la sola mansione: si aggancia
  -- quindi la parte dopo l'ultimo " - ". Senza questo il CDC restava vuoto per
  -- la maggior parte dei dipendenti (297 su 1364 lo prendevano, ora 1026).
  left join SIST_TIPI mans on mans.IdPadre=3
       and mans.Descrizione = ltrim(rtrim(
             case when charindex(' - ', u.Mansione) > 0
                  then right(u.Mansione, charindex(' - ', reverse(u.Mansione)) - 1)
                  else isnull(u.Mansione, '') end))
where ((u.IdCliente IS NULL))
and   len(isnull(u.CodiceFiscale,''))=16
and f.IdAzienda=2

GO
