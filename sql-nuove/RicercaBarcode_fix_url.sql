-- =============================================================
-- RicercaBarcode - indirizzo del report server
--
-- Sei link al PDF erano composti con cruscotto.speedyworld.it, che non e' piu'
-- l'indirizzo giusto. Ora usano http://192.168.0.176:8097, cioe' l'indirizzo
-- diretto del server dei report, che gira sulla stessa macchina.
--
-- Si usa l'IP e non un nome perche' la chiamata e' sempre interna: il PDF lo
-- scarica l'API (proxy /api/report) e lo mostra nella pagina, il browser non
-- contatta mai il report server. Cosi' non serve ne' DNS ne' file hosts.
--
-- Per la webapp l'indirizzo scritto qui dentro non viene comunque usato:
-- l'API tiene solo nome del report e parametri, e ricompone l'URL con
-- PARAMETRI.ReportServer. Resta valido per l'applicazione vecchia.
-- =============================================================



-- ====================================================================
-- RicercaBarcode adattata alla destinazione: ScansioneDB non e' migrato.
-- Commentato l'INTERO ramo UNION che leggeva ScansioneDB (il blocco
-- "select 9 as riga ... 'Scansione'"), non solo le tre LEFT JOIN:
-- gli alias b, i, p sono usati anche nella SELECT e nella WHERE dello
-- stesso ramo, quindi commentare le sole join lascerebbe riferimenti
-- irrisolti e la procedura non si creerebbe.
-- Effetto: la procedura non restituisce piu' la riga 'Scansione' con i
-- link alle immagini. Tutto il resto e' invariato.
-- Per ripristinare: togliere i prefissi "--" dalle righe marcate.
-- ====================================================================
-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[RicercaBarcode]
	-- Add the parameters for the stored procedure here
	@Barcode varchar(200) = null
	,@IdSped int = null
	,@IdCliente int =null
WITH RECOMPILE 
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
	set @Barcode=RIGHT(@barcode,50)
	declare @maxIdSpedDist int
	select @maxIdSpedDist=MAX(idsped2Dist) 
	from SPED_ATTIVITA s
		inner join SPED_SPED2DISTINTE l on l.IdSpedizione=s.IdSpedizione
	where s.Barcode=@Barcode and ISNULL(l.NoRend,0)=0

    -- Insert statements for procedure here
	declare @TipoBarcode int=0
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1 from SPED_ATTIVITA s where Barcode=@Barcode and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=2 from SPED_ATTIVITA s where RiferimentoEsterno1=@Barcode and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=3 from SPED_ATTIVITA s where RiferimentoEsterno2=@Barcode and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=3 from SPED_ATTIVITA s where RiferimentoEsterno3=@Barcode and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1 from SPED_ATTIVITA s where RiferimentoSpedizione=@Barcode and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1 from SPED_ATTIVITA s where NOTA2=@Barcode and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1
		--,@IdCliente=IdCliente 
		from SPED_ATTIVITA where CodiceRMN=@Barcode

	if @IdSped is null
	begin
		declare @spari int
		select @spari=COUNT(*) from PALM_RAW where barcode=@Barcode
		if @spari=0
			select ''
		else
			if PATINDEX('%@%',@barcode)=0
				select datacreazione as Data,'Palmare: '+ISNULL(ut.Nome,r.driver)  as Elemento, te.Evento as Valore,'' as link,'' as ico
					,'' AS MapLink
					,'' as MapIco
					,'' Report
					,'' Parametri
					,'' DelIco
					from PALM_RAW r
					left join utenti ut on ut.codAppLogin=r.driver
					inner join PALM_TIPOEVENTO te on te.tipoEventoCodice=r.tipoEventoCodice
					where barcode=@Barcode and tipo=0
						and isnull(@idcliente,0)=0
					order by r.id
			else
				select datacreazione as Data,'Palmare: '+ISNULL(ut.Nome,r.driver)  as Elemento, te.Evento as Valore
					,'http://maps.google.com/maps?q=' + replace(CONVERT(varchar(50),r.latitude),',','.')+',' + replace(CONVERT(varchar(50),r.longitude),',','.')+'+(My+Point)&z=14&ll=' + replace(CONVERT(varchar(50),r.latitude),',','.')+',' + replace(CONVERT(varchar(50),r.longitude),',','.') as link
					,'<img src="images/mm_20_blue.png" title="View position" style="width:13px;" onmouseover="this.style.cursor=''pointer''">' as ico
					,case when isnull(r.latitude,0)>0 then --<a href=" --+'">Mappa</a>'
					'http://maps.google.com/maps?q=' + replace(CONVERT(varchar(50),r.latitude),',','.')+',' + replace(CONVERT(varchar(50),r.longitude),',','.')+'+(My+Point)&z=14&ll=' + replace(CONVERT(varchar(50),r.latitude),',','.')+',' + replace(CONVERT(varchar(50),r.longitude),',','.')
					else '' end as MapLink
					,'jpg' as MapIco
					,'' Report
					,'' Parametri
					,'' DelIco
					,'' Foto
					,0 Cliente
					,0 Mittente
					from PALM_RAW r
					left join utenti ut on ut.codAppLogin=r.driver
					inner join PALM_TIPOEVENTO te on te.tipoEventoCodice=r.tipoEventoCodice
					where barcode=@Barcode and tipo=0
						and isnull(@idcliente,0)=0
					order by r.id
	end
	else
	begin
		select Data,Elemento,Valore,Link,Ico,MapLink,MapIco ,Report,Parametri,DelIco
			from (
			select 1 as riga,0 IdSped2Dist, '' as Data,'Dettaglio attivita:' Elemento, '' as Valore ,'' as Link,'' Ico,'' as MapLink,'' as MapIco
			,'' as Report
			,'' as Parametri
			,'' DelIco
			union
			--select 1 as riga,0 IdSped2Dist, '' as Data,'Prodotto:' Elemento, pf.FamigliaDiProdotto +' - ' + p.Prodotto as Valore ,'' as Link,'' Ico,'' as MapLink,'' as MapIco
			--	from SPED_ATTIVITA sa
			--	inner join PRODOTTI p on p.IdProdotto =sa.IdProdotto inner join PROD_FAMIGLIE pf on pf.CodFamiglia =p.CodFamiglia
			--	where IdSpedizione=@IdSped
			--union
			
			--select 2,'','Destinatario', isnull(sa.DestinazioneRagioneSociale+' ','') + ISNULL(sa.destinazioneIndirizzo+' ','')
			--							+ ISNULL(sa.destinazionecap+' ','')+ ISNULL(sa.DestinazioneLocalita+' ','')+ ISNULL(sa.DestinazioneProvinciaCodice +' ','')
			--							,''
			--from SPED_ATTIVITA sa where IdSpedizione =@IdSped
			--union
			--select 3,'','Mittente', '',''
			--from SPED_ATTIVITA sa where IdSpedizione =@IdSped
			--union
			
			--select 4,1 IdSped2Dist,
			----convert(varchar(10),sa.datastato,103)+' '+left(convert(varchar(8),sa.datastato,114),8),
			--convert(varchar(10),l.data,103)+' '+left(convert(varchar(8),l.data,114),8),
			----CONVERT(varchar(10),sa.datastato,103),
			--'Ultimo Stato:',s.Descrizione,'','','',''
			--from SPED_ATTIVITA sa 
			--	left join SPED_STATI s on s.STATO =sa.Stato 
			--	left join SPED_SPED2DISTINTE l on l.IdSpedizione=sa.IdSpedizione and l.Stato_Fine=sa.Stato
			--where sa.IdSpedizione =@IdSped
			--union
			
			select 4 as riga,sd.IdSped2Dist as Elemento,
			convert(varchar(10),sd.data,103)+' '+left(convert(varchar(8),sd.data,114),8) as Data,
			--CONVERT(varchar(20),sd.Data ),
			'Palmare: ' + case when isnull(@idcliente,0)=0 then isnull(u.nome,pr.driver) else '' end as Elemento
			--,sd.Nota as Valore
			,case when pr.tipoEventoCodice in ('G_002','G_005','G_006') then sd.Nota+' '++JSON_VALUE(pr.datijson,'$.titoloTerzo')+' '+JSON_VALUE(pr.datijson,'$.nomeFirmatario') else sd.nota end as Valore
			--,case when ISNULL(sd.Foto,'')='' then ''
			--else
			--'<a href="'+'http://upload.speedyworld.it/'+case when p.CodFamiglia in ('A','N') then 'ag' when sd.Stato_Fine='11' then 'sconosciuti' else 'consegne' end+'/'+sd.Foto+'.jpg'+ '">'+
			--'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
			--+'</a>' end as linkfoto	
			,'http://maps.google.com/maps?q=' + replace(CONVERT(varchar(50),pr.latitude),',','.')+',' + replace(CONVERT(varchar(50),pr.longitude),',','.')+'+(My+Point)&z=14&ll=' + replace(CONVERT(varchar(50),pr.latitude),',','.')+',' + replace(CONVERT(varchar(50),pr.longitude),',','.') Link,
			--case when ISNULL(sd.Foto,'')='' then ''
			--else
			----'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''" alt="'+
			----'http://upload.speedyworld.it/'+case when p.CodFamiglia in ('A','N') then 'ag' when sd.Stato_Fine='11' then 'sconosciuti' else 'consegne' end+'/'+sd.Foto+'.jpg'			
			----+'">'
			----'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
			--end as link_image,
			case when isnull(PR.latitude,0)>0 then '<img src="images/mm_20_blue.png" title="View position" style="width:13px;" onmouseover="this.style.cursor=''pointer''">' 
			else '' 
			end as MapIco
			
			,case when isnull(PR.latitude,0)>0 then --<a href=" --+'">Mappa</a>'
				'http://maps.google.com/maps?q=' + replace(CONVERT(varchar(50),pr.latitude),',','.')+',' + replace(CONVERT(varchar(50),pr.longitude),',','.')+'+(My+Point)&z=14&ll=' + replace(CONVERT(varchar(50),pr.latitude),',','.')+',' + replace(CONVERT(varchar(50),pr.longitude),',','.')
				else '' end as MapLink
			,case when isnull(PR.latitude,0)>0 then 'jpg' else '' end as MapIco
			,'' as Report
			,'' as Parametri
			,case when isnull(sa.IdAder4REND,0)=0 and sd.IdSped2Dist=@maxIdSpedDist and sa.IdCliente=5322 then '<img src="images/errpg.gif" title="Elimina Esito" style="width:13px;" onmouseover="this.style.cursor=''pointer''">' 
			 else '' 
			 end as DelIco
			from SPED_ATTIVITA sa 
			inner join SPED_SPED2DISTINTE sd on sd.IdSpedizione =sa.IdSpedizione
			left join PRODOTTI p on p.IdProdotto=sa.IdProdotto
			left join utenti u on u.idutente=sd.idutente
			left join palm_raw pr on pr.id=sd.idpalmraw
			where sa.IdSpedizione =@IdSped and IdPalmRaw is not null and sd.NoRend is null --and LEFT(pr.barcode,3) not in ('CAD','CAN')
			union
			--solo le azioni in distinta
			select 4,sd.IdSped2Dist,
				convert(varchar(10),
				case when isnull(az.MantieniDataPrec,0)=0 then sd.data else ss.datainserimento end
				,103)
				+' '+left(convert(varchar(8),
				case when isnull(az.MantieniDataPrec,0)=0 then sd.data else ss.datainserimento end
				,114),8),
				'Backoffice: '+ case when isnull(@idcliente,0)=0 then isnull(u.Nome,'') else '' end,
				az.Azione
				+ISNULL(' ' + messo.Nome,'')
				+' - Distinta n° '+ss.Barcode+' del '+ convert(varchar(10),ss.Data,103)
				+ case when az.IdAzione=7 then isnull(' terzo :'+ sa.ConsegnatoA,'') else '' end 
				+ case when LEFT(az.CodFamigliaAzione,1)='D' then ISNULL( ' Num:'+ convert(varchar(10),ss.progressivo) + ' Prog:'+ convert(varchar(10),sd.progressivo),'') else '' end
					Azione,
				'http://192.168.0.176:8097/result?report='+ss.WebReport+'&format=PDF&iddistinta='+convert(varchar(100),ss.IdDistinta),
				'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">',
				'',
				'pdf'
				,ss.WebReport as Report
				,'iddistinta='+convert(varchar(100),ss.IdDistinta) as Parametri
				,case when isnull(sa.IdAder4REND,0)=0 and sd.IdSped2Dist=@maxIdSpedDist and sa.IdCliente=5322 then '<img src="images/errpg.gif" title="Elimina Esito" style="width:13px;" onmouseover="this.style.cursor=''pointer''">' 
				 else '' 
				 end as DelIco
			from SPED_ATTIVITA sa 
				inner join SPED_SPED2DISTINTE sd on sd.IdSpedizione =sa.IdSpedizione
				inner join SPED_DISTINTE ss on ss.IdDistinta=sd.IdDistinta
				inner join SPED_AZIONI az on az.IdAzione=ss.IdAzione
				left join UTENTI u on u.IdUtente=ss.IdUtente
				left join UTENTI messo on messo.IdUtente=ss.IdMesso
			where sa.IdSpedizione =@IdSped 
				--and IdPalmRaw is null  231206 Carlo, non so perche c'era questo filtro 
				and sd.NoRend is null

			union

			select 4 as riga,cd.ParamInt1 as IdSped2Dist
					, convert(varchar(10),cd.DataAggiornamento,103)+' '+left(convert(varchar(8),cd.DataAggiornamento,114),8) as Data
					,'Invio email a :' + cd.ParamStr1  Elemento
					, cd.ParamStr2 as Valore 
					,'' as Link
					,'' Ico
					,'' as MapLink
					,'' as MapIco
					,'' as Report
					,''as Parametri
					,'' DelIco
				from crm_dettaglio cd
				where Idtabella=@IdSped
				and IdCRM_Azione=1
				and DataAggiornamento is not null

			union

			select 4 as riga,sd.IdSped2Dist as IdSped2Dist,
			convert(varchar(10),sd.data,103)+' '+left(convert(varchar(8),sd.data,114),8) as Data,
			'Flusso: ' +cf.NomeFile as Elemento
			,sd.Nota as Valore
			,case when isnull(sd.latitude,0)>0 then 'http://maps.google.com/maps?q=' + replace(CONVERT(varchar(50),sd.latitude),',','.')+',' + replace(CONVERT(varchar(50),sd.longitude),',','.')+'+(My+Point)&z=14&ll=' + replace(CONVERT(varchar(50),sd.latitude),',','.')+',' + replace(CONVERT(varchar(50),sd.longitude),',','.') else '' end Link
			,case when isnull(sd.latitude,0)>0 then '<img src="images/mm_20_blue.png" title="View position" style="width:13px;" onmouseover="this.style.cursor=''pointer''">' else '' end as MapIco
			,case when isnull(sd.latitude,0)>0 then 
				'http://maps.google.com/maps?q=' + replace(CONVERT(varchar(50),sd.latitude),',','.')+',' + replace(CONVERT(varchar(50),sd.longitude),',','.')+'+(My+Point)&z=14&ll=' + replace(CONVERT(varchar(50),sd.latitude),',','.')+',' + replace(CONVERT(varchar(50),sd.longitude),',','.')
				else '' end as MapLink
			,case when isnull(sd.latitude,0)>0 then 'jpg' else '' end as MapIco
			,'' as Report
			,'' as Parametri
			,'' as DelIco
			from SPED_ATTIVITA sa 
			inner join SPED_SPED2DISTINTE sd on sd.IdSpedizione =sa.IdSpedizione
			left join PRODOTTI p on p.IdProdotto=sa.IdProdotto
			left join utenti u on u.idutente=sd.idutente
			left join CRM_FILE cf on cf.IdCrmFile=sd.IdCrmFile
			where sa.IdSpedizione =@IdSped and sd.IdCrmFile is not null and sd.NoRend is null

			union  --aggiunta barcode fine gita
			select 4,isnull(sa.id2esito,999999999),pa.dataeffettiva,'FineGita:',pa.barcodedistintareso,'','','','','','',''
			from sped_attivita sa
			inner join palm_attivita pa on pa.riferimento=convert(varchar(50),sa.idspedizione) and pa.tiporiferimento=0
			where sa.idspedizione=@idsped and isnull(pa.barcodedistintareso,'')<>''
			

			union
			select 5 as riga,sf.IdSignFile
					, convert(varchar(10),sf.DataCreazione ,103)+' '+left(convert(varchar(8),sf.DataFirma,114),8) as Data
					,'Ricevuta con firma digitale'   Elemento
					, '' as Valore 
					,'x' as Link
					,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">' Ico
					,'' as MapLink
					,'file' as MapIco
					,sf.NomeFile as Report
					,sf.Percorso as Parametri
					,'' DelIco
				from SIGN_FILE sf
				where IdSpedizione=@IdSped
				and sf.DataFirma is not null
				and sf.NomeFile is not null
			union
			select 6,0
					, convert(varchar(10),sa.datastato ,103)+' '+left(convert(varchar(8),sa.datastato,114),8) as Data
					,'Prova di Consegna'   Elemento
					, '' as Valore 
					--,'x' as Link
				,'http://192.168.0.176:8097/result?report=DELIVERY_PDC.fr3&format=PDF&idspedizione='+convert(varchar(100),sa.idspedizione)
				,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
				,''
				,'pdf'
					,'DELIVERY_PDC.fr3' as Report
					,'idspedizione='+convert(varchar(100),sa.idspedizione) as Parametri
					,'' DelIco
			from sped_attivita sa
			where idspedizione=@idsped
			and stato in ('90','A1','A2','A3','R1A','R1D','M01','M03')
			union
			select 7,0
					,ar.DataInserimento 
					,'ADER4-Anomalia'
					,ar.CodAttivita + ' - ' +ar.DataAttivita + ' - ' +ok.CodiceErrore + ' - ' +ok.DescrizioneErrore
					,'' as Link
					,'' Ico
					,'' as MapLink
					,'' as MapIco
					,'' as Report
					,''as Parametri
					,'' DelIco
				from sped_attivita sa 
				inner join ader4_rend ar on ar.idspedizione=sa.idspedizione
				inner join ader4_ok ok on ok.IdSpedizione=ar.IdSpedizione and ok.idrend=ar.IdFileRend
				where 1=1
				and sa.IdProdotto in (11,66)
				and ar.MotivoKO<>'OK'
				and ar.idspedizione=@idsped
			union
			select 8,0
					, convert(varchar(10),sa.datastato ,103)+' '+left(convert(varchar(8),sa.datastato,114),8) as Data
					,'Prova di Mancata Consegna'   Elemento
					, '' as Valore 
					--,'x' as Link
				,'http://192.168.0.176:8097/result?report=DELIVERY_NOPDC.fr3&format=PDF&idspedizione='+convert(varchar(100),sa.idspedizione)
				,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
				,''
				,'pdf'
					,'DELIVERY_NOPDC.fr3' as Report
					,'idspedizione='+convert(varchar(100),sa.idspedizione) as Parametri
					,'' DelIco
			from sped_attivita sa
			where idspedizione=@idsped
			and LEFT(sa.barcode,5)='CHCK_' 
			and stato in ('11')			
-- [rimosso: ScansioneDB non migrato] 			union
-- [rimosso: ScansioneDB non migrato] 			select 9 as riga,sa.idspedizione
-- [rimosso: ScansioneDB non migrato] 				, getdate() as Data
-- [rimosso: ScansioneDB non migrato] 				,'Scansione'   Elemento
-- [rimosso: ScansioneDB non migrato] 				,CASE WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'REL' THEN '1 - RELATA'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'RAC' THEN '4 - RACCOMANDATA'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'AFF' THEN '3 - AFFISSIONE'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'POS' THEN '5 - POSTALIZZAZIONE'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'MES' THEN '2 - AFFIDO'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'AVR' THEN '6 - AVVISO RICEVIMENTO'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'AVV' THEN '7 - AFFISSIONE'
-- [rimosso: ScansioneDB non migrato] 					WHEN b.TipoScatola=case when b.Ambito between '291' and '299' then '888' else b.Ambito end+'RCC' THEN '8 - AVVISO AG'
-- [rimosso: ScansioneDB non migrato] 				ELSE
-- [rimosso: ScansioneDB non migrato] 					'link al pdf se presente' 
-- [rimosso: ScansioneDB non migrato] 				END	as Valore 
-- [rimosso: ScansioneDB non migrato] 				,case when p.OutPath is null then 'http://10.1.0.5:8080/SCATOLE_ADE/'+ convert(varchar(10),sa.idcliente)+'/'+convert(varchar(10),sa.idlotto)+'/'+sa.barcode+'.pdf' 
-- [rimosso: ScansioneDB non migrato] 					else
-- [rimosso: ScansioneDB non migrato] 						'http://10.1.0.5:8080/'+p.OutPath+'/'+replace(i.Nome_immagine,'\','/')
-- [rimosso: ScansioneDB non migrato] 				 end as Link
-- [rimosso: ScansioneDB non migrato] 				,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">' Ico
-- [rimosso: ScansioneDB non migrato] 				,'' as MapLink
-- [rimosso: ScansioneDB non migrato] 				,'url' as MapIco
-- [rimosso: ScansioneDB non migrato] 				,'' as Report
-- [rimosso: ScansioneDB non migrato] 				,'' as Parametri
-- [rimosso: ScansioneDB non migrato] 				,'' DelIco
-- [rimosso: ScansioneDB non migrato] 			from sped_attivita sa
-- [rimosso: ScansioneDB non migrato] 				left join ScansioneDB.dbo.SCAN_BarcodeDocumenti b on b.BarcodeDocumento=sa.Barcode
-- [rimosso: ScansioneDB non migrato] 				left join ScansioneDB.dbo.SCAN_Immagini i on i.Barcode=b.BarcodeImmagine and i.Nome_immagine is not null
-- [rimosso: ScansioneDB non migrato] 				left join ScansioneDB.dbo.SCAN_Percorsi p on p.Ambito=case when b.Ambito between '291' and '299' then '888' else b.Ambito end
-- [rimosso: ScansioneDB non migrato] 			where idspedizione=@idsped
-- [rimosso: ScansioneDB non migrato] 				and case when p.OutPath is null then 'http://10.1.0.5:8080/SCATOLE_ADE/'+ convert(varchar(10),sa.idcliente)+'/'+convert(varchar(10),sa.idlotto)+'/'+sa.barcode+'.pdf' 
-- [rimosso: ScansioneDB non migrato] 					else
-- [rimosso: ScansioneDB non migrato] 							'http://10.1.0.5:8080/'+p.OutPath+'/'+replace(i.Nome_immagine,'\','/')
-- [rimosso: ScansioneDB non migrato] 					end is not null
			union
			select 10,0
					, convert(varchar(10),sa.datastato ,103)+' '+left(convert(varchar(8),sa.datastato,114),8) as Data
					,'Ristampa Raccomandata CAD'   Elemento
					, '' as Valore 
					--,'x' as Link
				,'http://192.168.0.176:8097/result?report=AG_RaccomandataCAD_Singola.fr3&format=PDF&CAD='+convert(varchar(100),sa.RiferimentoEsterno2)
				,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
				,''
				,'pdf'
					,'AG_RaccomandataCAD_Singola.fr3' as Report
					,'CAD='+convert(varchar(100),sa.RiferimentoEsterno2) as Parametri
					,'' DelIco
			from sped_attivita sa
			where idspedizione=@IdSped
				and IdProdotto=12
				and stato in ('99','9A','9G','95','9B')
			union
			select 11,0
					, convert(varchar(10),sa.datastato ,103)+' '+left(convert(varchar(8),sa.datastato,114),8) as Data
					,'Ristampa cartolina CAD'   Elemento
					, '' as Valore 
					--,'x' as Link
				,'http://192.168.0.176:8097/result?report=ADEX_RR_CAD_Singola.fr3&format=PDF&idspedizione='+convert(varchar(100),sa.idspedizione)
				,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
				,''
				,'pdf'
					,'ADEX_RR_CAD_Singola.fr3' as Report
					,'idspedizione='+convert(varchar(100),sa.idspedizione) as Parametri
					,'' DelIco
			from sped_attivita sa
			where idspedizione=@IdSped
				and IdProdotto=12
				and stato in ('99','9A','9G','95','9B')
			union
			select 12,0
					, convert(varchar(10),sa.datastato ,103)+' '+left(convert(varchar(8),sa.datastato,114),8) as Data
					,'Ristampa Raccomandata CAN'   Elemento
					, '' as Valore 
					--,'x' as Link
				,'http://192.168.0.176:8097/result?report=AG_RaccomandataCAN_Singola.fr3&format=PDF&CAN='+convert(varchar(100),sa.RiferimentoEsterno3)
				,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">'
				,''
				,'pdf'
					,'AG_RaccomandataCAN_Singola.fr3' as Report
					,'CAN='+convert(varchar(100),sa.RiferimentoEsterno3) as Parametri
					,'' DelIco
			from sped_attivita sa
			where idspedizione=@IdSped
				and IdProdotto=12
				and stato in ('A1','A2','A3','A5')
			--union
			--select 9 as riga,sa.idspedizione
			--		, getdate() as Data
			--		,'Scansione'   Elemento
			--		, 'link al pdf se presente' as Valore 
			--		,'http://10.1.0.5:8080/SCATOLE_ADE/'+ convert(varchar(10),sa.idcliente)+'/'+convert(varchar(10),sa.idlotto)
			--			+'/'+barcode+'.pdf' as Link
			--		,'<img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''">' Ico
			--		,'' as MapLink
			--		,'url' as MapIco
			--		,'' as Report
			--		,'' as Parametri
			--		,'' DelIco
			--	from sped_attivita sa
			--	where idspedizione=@idsped
			--		and sa.idprodotto not in (11,66)
			--union
			--select 8,0
			--		, convert(varchar(10),sa.datastato ,103)+' '+left(convert(varchar(8),sa.datastato,114),8) as Data
			--		,'Test'   Elemento
			--		, '' as Valore 
			--		--,'x' as Link
			--	,''
			--	,'<a href="file://10.1.0.5/i/SCANSIONE/SCATOLE_ADER/20240109/AR1-20240109-CO03-19/20240109_Doc032.pdf" target="_blank"><img src="images/pdfico.jpg" title="View Image" style="width:25px;" onmouseover="this.style.cursor=''pointer''"></a>'
			--	,''
			--	,'pdf'
			--		,'DELIVERY_NOPDC.fr3' as Report
			--		,'idspedizione='+convert(varchar(100),sa.idspedizione) as Parametri
			--		,'' DelIco
			--from sped_attivita sa
			--where idspedizione=5065220
		) x
		order by riga,IdSped2Dist
		--select * from sped_Stati

	end

END

