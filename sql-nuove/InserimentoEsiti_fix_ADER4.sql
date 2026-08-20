-- =============================================================
-- InserimentoEsiti - blocco ADER4 disattivato (agosto 2026)
--
-- Sul database di produzione (BLUE) non esiste piu' la funzione
-- dbo.ADER4_VerificaAssenti: la procedura andava in errore invece di
-- completare l'inserimento degli esiti.
--
-- Qui e' commentato SOLO il pezzo che la chiamava ("continua il toppone
-- ADER4"): riguardava le distinte con IdAzione 1105 e 1140 e ricalcolava
-- lo stato degli assenti con codice fiscale di persona fisica.
-- Il resto della procedura, compresa la prima "TOPPA ADER4" che usa solo
-- tabelle esistenti, e' rimasto invariato.
--
-- Se quella lavorazione dovesse tornare: ripristinare prima la funzione,
-- poi togliere il commento.
--
-- Il file e' la definizione COMPLETA cosi' com'e' sul server, con l'unica
-- differenza del blocco commentato: si puo' rieseguire tale e quale.
-- =============================================================


-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[InserimentoEsiti]
	-- Add the parameters for the stored procedure here
	@IdAzione int
	,@Data date = null
	,@BarcodeDistinta varchar(100) = null
	,@ElencoBarcode varchar(max) = null
	,@ElencoIdAttivita	varchar(max)=null
	,@ElencoQualifiche varchar(max)=null
	,@ElencoConsegnatoA varchar(max)=null
	,@ElencoNote varchar(max)=null
	,@IdUtente int = null
	,@IdPostino int = null
	,@Belfiore varchar(15) = null
	,@IdFiliale int =null
	,@IdFilialeDestinazione int = null
	,@IdDistinta int =null output
	,@WebReport varchar(100)=null output

	,@Result varchar(1000) = null output
	,@Param1Tipo varchar(10) =null
	,@TipoParametri1 varchar(max)=null
	,@ElencoParametri1 varchar(max)=null
	,@TipoParametri2 varchar(max)=null
	,@ElencoParametri2 varchar(max)=null
	,@IdFilialeGiacenza int = null
	,@Scatola varchar(100) = null
	,@quiet int =0
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;
	declare @IdScatola int

	declare @Comando varchar(200)=''
	set @Comando='Scrittura Log'
	insert into log_exec (chiamata,parametri,datainserimento)
	select 'inserimentoesiti'
		,left(
		isnull('vers.1.6.1, @idazione='+convert(varchar(20),@idazione),'')
		+isnull(',@ElencoBarcode='+@ElencoBarcode,'')
		+isnull(',@ElencoIdAttivita='+@ElencoIdAttivita,'')
		+isnull(',@ElencoQualifiche='+@ElencoQualifiche,'')
		+isnull(',@ElencoConsegnatoA='+@ElencoConsegnatoA,'')
		+isnull(',@ElencoNote='+@ElencoNote,'')
		+isnull(',@IdUtente='+convert(varchar(20),@IdUtente),'')
		+isnull(',@IdPostino='+convert(varchar(20),@IdPostino),'')
		+isnull(',@IdFiliale='+convert(varchar(20),@IdFiliale),'')
		+isnull(',@IdFilialeDestinazione='+convert(varchar(20),@IdFilialeDestinazione),'')
		+isnull(',@IdFilialeGiacenza='+convert(varchar(20),@IdFilialeGiacenza),'')
		+isnull(',@Belfiore='+@Belfiore,'')
		+isnull(',@TipoParametri1='+@TipoParametri1,'')
		+isnull(',@ElencoParametri1='+@ElencoParametri1,'')
		+isnull(',@TipoParametri2='+@TipoParametri2,'')
		+isnull(',@ElencoParametri2='+@ElencoParametri2,'')
		+isnull(',@Scatola='+@Scatola,'')
		+isnull(',@Belfiore='+@Belfiore,'')
		,4000)
		,getdate()

	--caso di casa comunale
	Declare @IdCasaComunale int
	if len(trim(@belfiore))>4
	begin
		set @IdCasaComunale=convert(int,substring(@belfiore,6,10))
		set @belfiore=substring(@belfiore,1,4)
	end

	declare @DataAttuale smalldatetime
	declare @CodFamigliaAzione varchar(5)
	declare @AggiornaSpedizione int
		,@EsitoFinale int
		,@ForzaFilialeDestinazione int=0
		,@ForzaFilialeGiacenza int=0
		,@Chiedi_Terzi int=0
		,@Chiedi_Operatore int = 0
		,@TipoDistinta varchar(10)=''
		,@IdProdottoGenerato int
		,@MantieniDataPrec int = 0
		,@AttiChiusi int =0
	set @DataAttuale =getdate()

	select @AggiornaSpedizione =az.AggiornaSpedizione 
			,@EsitoFinale=az.esitofinale
			,@CodFamigliaAzione=az.CodFamigliaAzione
			,@ForzaFilialeDestinazione=az.Chiedi_FilialeDest
			,@ForzaFilialeGiacenza=az.Chiedi_FilialeGiac
			,@Chiedi_Terzi=az.Chiedi_Terzi
			,@Chiedi_Operatore=az.Chiedi_Operatore
			,@TipoDistinta=az.tipodistinta
			,@IdProdottoGenerato=az.idprodottogenerato
			,@MantieniDataPrec=az.mantienidataprec
			,@Param1Tipo=az.Param1_Tipo
			,@AttiChiusi=attichiusi
		from SPED_AZIONI az where az.IdAzione=@IdAzione
	
	set @Comando='Creo Elenco'

	create table #elenco (
		position int
		,idspedizione int
		,barcode varchar(100) COLLATE Latin1_General_CI_AS
		,stato varchar(50) COLLATE Latin1_General_CI_AS 
		,qualifica varchar(200) COLLATE Latin1_General_CI_AS
		,ConsegnatoA varchar(200) COLLATE Latin1_General_CI_AS
		,NotaConsegna varchar(1000) COLLATE Latin1_General_CI_AS
		,TipoParametro1 varchar(200) COLLATE Latin1_General_CI_AS
		,ElencoParametro1 varchar(4000) COLLATE Latin1_General_CI_AS
		,TipoParametro2 varchar(200) COLLATE Latin1_General_CI_AS
		,ElencoParametro2 varchar(4000) COLLATE Latin1_General_CI_AS
		,forzastato int
		,tot int
		)
    -- Popolo la #elenco con posizione e idspedizione o barcode
	set @Comando='Popolo Elenco'
	if @ElencoIdAttivita is not null
		begin --se mi passano idattività è facile
			insert into #elenco  (position,idspedizione)
			select position,value 
			from splitstring(@ElencoIdAttivita,',') x
		end	
	else
	begin  --Carlo 23/10/13
		insert into #elenco  (position,barcode)
		select position,value 
		from splitstring(@ElencoBarcode,',') x
	end

	--se mi passano i barcode devo decodificare e trovare idattivita
	


		--if (@Idazione in (12,1035,10))
		--	--Francesco 10/02/2022 - Controllo che non sia stato inserito il barcode di una ricevuta di ritorno
		--	insert into #elenco  (position,barcode)
		--	select x.position,case when sBusta.Barcode is null then sCartolina.Barcode else sBusta.Barcode end value
		--	from splitstring(@ElencoBarcode,',') x
		--		left join SPED_ATTIVITA sBusta on sBusta.Barcode=x.value
		--		left join SPED_ATTIVITA sCartolina on sCartolina.RiferimentoEsterno1=x.value
		--else



	--Cerco il barcode. Modifica Carlo 11/10/2023
	update #elenco 	set idspedizione=x.idspedizione,tot=x.tot
	from #elenco e
	inner join (
		select MAX(a.IdSpedizione) idspedizione,a.barcode,COUNT(*) as tot from #elenco e
		-- 23/11/2021 Francesco modificare per riconoscere il barcode della RR nel reso cartoline
		inner join SPED_ATTIVITA a on a.barcode =e.barcode
		left join sped_lotti l on l.idlotto=a.idlotto 
		--where 1=1 or (a.datafine is null and @IdAzione <>1155)
		--240208 Carlo: controllo che il barcode appartenga a un lotto con checkin effettuato e non chiuso 
						--oppure è parcel e non ha il lotto
						--oppure è una azione di reso
		where (l.DataAccettazione is not null
				and a.datafine is null 
				and ISNULL(@attichiusi,0) =0)
			or a.IdProdotto=1
			or ISNULL(@attichiusi,0) <>0
		group by a.barcode
	)x on x.Barcode =e.barcode and e.idspedizione is null

	update #elenco 	set idspedizione=x.idspedizione,tot=x.tot
	from #elenco e
	inner join (
		select MAX(a.IdSpedizione) idspedizione,a.RiferimentoEsterno1,COUNT(*) as tot from #elenco e
		inner join SPED_ATTIVITA a on a.RiferimentoEsterno1 =e.barcode
		left join sped_lotti l on l.idlotto=a.idlotto 
		--where 1=1 or (a.datafine is null and @IdAzione <>1155)
		--240208 Carlo: controllo che il barcode appartenga a un lotto con checkin effettuato e non chiuso 
						--oppure è parcel e non ha il lotto
						--oppure è una azione di reso
		where (l.DataAccettazione is not null
				and a.datafine is null 
				and ISNULL(@attichiusi,0) =0)
			or a.IdProdotto=1
			or ISNULL(@attichiusi,0)<>0
		group by a.RiferimentoEsterno1
		)x on x.RiferimentoEsterno1 =e.barcode 
		and e.idspedizione is null

	--se sono raccomandate ader4 cerco in codice_rmn
	update #elenco 	set idspedizione=a.idspedizione
	from #elenco e
	inner join SPED_ATTIVITA a on a.CodiceRMN =e.barcode
	where a.datafine is null
	and e.idspedizione is null

	--  se sono ADEX e sono le azione 1180 e 1181 le cerco tra i lotti non accettati
	update #elenco 	set idspedizione=a.idspedizione
	from #elenco e
	inner join SPED_ATTIVITA a on a.barcode =e.barcode
	left join sped_lotti l on l.idlotto=a.idlotto 
	where l.DataAccettazione is null
		and @IdAzione in (1180,1181)
	and e.idspedizione is null

	--se ci sono aggiorno le qualifiche
	if @ElencoQualifiche is not null
	update #elenco
		set qualifica=x.value
	from #elenco e
	inner join (select position,value
				from SplitString(@ElencoQualifiche,'|' )) x on x.position=e.position

	--se ci sono aggiorno il campo ConsegnatoA
	if @ElencoConsegnatoA is not null
	update #elenco
		set ConsegnatoA=x.value
	from #elenco e
	inner join (select position,value
				from SplitString(@ElencoConsegnatoA,'|' )) x on x.position=e.position

	--se ci sono aggiorno il campo NotaConsegna
	if @ElencoNote is not null
	update #elenco
		set NotaConsegna=isnull(s.statoreso,x.value)
	from #elenco e
	inner join (select position,value
				from SplitString(@ElencoNote,'|' )) x on x.position=e.position
	left join sped_statiresi s on convert(varchar(20),s.IdStatoReso)=replace(x.value,';','')

	--se ci sono aggiorno Parametro1
	if @TipoParametri1 is not null
	update #elenco
		set TipoParametro1=x.value
	from #elenco e
	inner join (select position,value
				from SplitString(@TipoParametri1,'|' )) x on x.position=e.position

	if @ElencoParametri1 is not null
	update #elenco
		set ElencoParametro1=x.value
	from #elenco e
	inner join (select position,value
				from SplitString(@ElencoParametri1,'|' )) x on x.position=e.position
		
	--se l'azione è di inserimento di una notifica a terzi allora decodifico ElencoParametri1
	if isnull(@chiedi_terzi,0)=-1
	begin
		update #elenco
			set ConsegnatoA=substring(ElencoParametro1,charindex(';',ElencoParametro1)+1,len(ElencoParametro1))
			,qualifica=(select top 1 Qualifica from SIST_QUALIFICHE where IdQualifica=convert(int,substring(ElencoParametro1,1,charindex(';',ElencoParametro1)-1))) 
		from #elenco e
	end
		
	--se ci sono aggiorno Parametro2
	if @TipoParametri2 is not null
	update #elenco
		set TipoParametro2=x.value
	from #elenco e
	inner join (select position,value
				from SplitString(@TipoParametri2,'|' )) x on x.position=e.position

	if @ElencoParametri2 is not null
	update #elenco
		set ElencoParametro2=x.value
	from #elenco e
	inner join (select position,value
				from SplitString(@ElencoParametri2,'|' )) x on x.position=e.position



	begin try
		begin transaction tr1
		
			if isnull(@idazione,0)=0
				THROW 51000, 'ERRORE! Azione Vuota, avvertire Reparto IT', 1;  
 
			set @Comando='Calcolo Progressivo'
			declare @Progressivo int=null
			if @TipoDistinta is not null and @Belfiore is not null
			begin
				select @progressivo=max(progressivo) from SPED_DISTINTE sd
					where 1=1
					and sd.TipoDistinta=@TipoDistinta
					and year(sd.data)=year(@Data)
					and isnull(sd.Belfiore,'')=isnull(@Belfiore,'')
					and isnull(sd.IdCasaComunale,0)=isnull(@IdCasaComunale,0)
				set @Progressivo=isnull(@Progressivo,0)+1
			end

			set @Comando='Creazione Distinta'
			--creo la distinta
			insert into SPED_DISTINTE (IdAzione,Barcode,Data,Progressivo,TipoDistinta,Belfiore,IdCasaComunale,NumeroAtti,IdMesso,IdFiliale,IdFilialeDestinazione,IdUtente,DataInserimento,WebReport,IdFilialeGiacenza) 
			select @IdAzione,@BarcodeDistinta,@Data,@Progressivo,@TipoDistinta,@Belfiore,@IdCasaComunale,(select COUNT(*) from #elenco ),@IdPostino,@IdFiliale,@IdFilialeDestinazione,@IdUtente,GETDATE()
				,(select top 1 WebReport from SPED_AZIONI where IdAzione=@IdAzione),@IdFilialeGiacenza
			set @IdDistinta=SCOPE_IDENTITY()
			if @BarcodeDistinta is null
				set @BarcodeDistinta='5' + right('000'+CONVERT(varchar(10),@IdAzione),3)+right('00000000'+CONVERT(varchar(8),@iddistinta),8)			
			update SPED_DISTINTE set Barcode=@BarcodeDistinta where IdDistinta=@IdDistinta




			declare @stato_fine_default varchar(50)
			select @stato_fine_default=z.Stato_Fine  from SPED_AZIONI z where z.IdAzione =@IdAzione

			--inserisco le righe in sped2distinte
			set @Comando='Creazione Sped2Distinte'
			declare @prog int
			DECLARE db_cursor CURSOR FOR 
			select position from #elenco 
			OPEN db_cursor  
			FETCH NEXT FROM db_cursor INTO @prog 

			WHILE @@FETCH_STATUS = 0  
			BEGIN  
				declare @ForzaStato int
				declare @NotaAzione varchar(200)=''
				select @NotaAzione=Azione,@ForzaStato=Forzabile from SPED_AZIONI where IdAzione=@IdAzione

				--controllo lo stato finale, se è XX lo tolgo dall'elenco
				declare @StatoFine varchar(10)=''
				select @StatoFine=isnull(w.Stato_Fine,@stato_fine_default)
				from #elenco e
				inner join SPED_ATTIVITA a on a.IdSpedizione=e.idspedizione
				left join SPED_WORKFLOW  w on w.IdAzione=@IdAzione and isnull(w.Stato_Inizio,'') =isnull(a.Stato,'')
				where e.position =@prog

				
				if @StatoFine='XX' and isnull(@aggiornaspedizione,0)=-1 and isnull(@ForzaStato,0)=0
				begin
					--insert into LOG_Exec (chiamata,parametri)
					--select 'delete from #elenco',''
					delete from #elenco where position=@prog
				end
				else
				begin  --Se non e' XX proseguo come sempre 
					insert into SPED_SPED2DISTINTE (IdSpedizione,IdDistinta,Progressivo,Stato_Inizio,Stato_Fine,data
													,Nota,Qualifica,ConsegnatoA)
					select top 1 e.idspedizione,@IdDistinta,e.position,a.Stato
						,isnull(w.Stato_Fine,@stato_fine_default)
						,case when isnull(@mantienidataprec,0)=-1 then a.DataStato 
							when @IdAzione=1164 then GETDATE() 
							else @Data end 
						--,case when @TipoParametro1='NOTA' then e.elencoparametro1
						--		when @TipoParametro2='NOTA' then e.elencoparametro2
						--		else '' end
						,case when isnull(@Param1Tipo,'')<>'' then substring(e.ElencoParametro1,2,100) else @NotaAzione end
						--,case when @TipoParametro1='QUALIFICA' then e.elencoparametro1
						--		when @TipoParametro2='QUALIFICA' then e.elencoparametro2
						--		else '' end
						,e.qualifica
						--,case when @TipoParametro1='CONSEGNATOA' then e.elencoparametro1
						--		when @TipoParametro2='CONSEGNATOA' then e.elencoparametro2
						--		else '' end
						,e.ConsegnatoA
					from #elenco e
					inner join SPED_ATTIVITA a on a.IdSpedizione=e.idspedizione
					left join SPED_WORKFLOW  w on w.IdAzione=@IdAzione and isnull(w.Stato_Inizio,'') =isnull(a.Stato,'')
					where e.position =@prog
				
					set @Comando='Aggiorno SpedAttivita'
					update SPED_ATTIVITA
						set Stato=case when isnull(@aggiornaspedizione,0)=-1 then isnull(w.Stato_Fine,@stato_fine_default) else a.stato end
							,DataStato=case when isnull(@aggiornaspedizione,0)=-1 and isnull(@mantienidataprec,0)=0 then @Data else a.DataStato end
							,IdDistintaLast =case when @CodFamigliaAzione='P' then a.IdDistintaLast 
												  when @CodFamigliaAzione='S' then a.IdDistintaLast 
												  when isnull(@aggiornaspedizione,0)=-1 then @IdDistinta
												  else a.IdDistintaLast end
							,IdFiliale=@IdFiliale
							,IdFilialeDestinazione=ISNULL(case when isnull(@ForzaFilialeDestinazione,0)=-1 then @idfilialedestinazione else a.IdFilialeDestinazione end,a.IdFilialeDestinazione)
							--,IdFilialeGiacenza=ISNULL(case when @ForzaFilialeGiacenza=-1 then @idfilialedestinazione else a.IdFilialeGiacenza end,a.IdFilialeGiacenza)
							,IdFilialeGiacenza=ISNULL(case when isnull(@ForzaFilialeGiacenza,0)=-1 then case when @idAzione=1050 then @idfilialeGiacenza else @idfilialedestinazione end else a.IdFilialeGiacenza end,a.IdFilialeGiacenza)
							,datafine=case when isnull(@CodFamigliaAzione,'')='S' then @DataAttuale else a.datafine end
							--aggiorno ConsegnatoA solo se esito finale e esiste 
							,ConsegnatoA=case when len(e.ConsegnatoA)>1 then e.ConsegnatoA else a.ConsegnatoA end
							,Qualifica=case when len(e.qualifica)>1 then e.qualifica else a.Qualifica end
							,NotaConsegna=case when isnull(@EsitoFinale,0)=-1 and len(e.NotaConsegna)>0 then e.NotaConsegna else a.NotaConsegna end
							,iddistintaesito=case when isnull(@EsitoFinale,0)=-1 then @IdDistinta else null end
							,forzagiacenza=case when isnull(@ForzaFilialeGiacenza,0)=-1 then -1 else a.forzagiacenza end
							,IdUtente=isnull(@IdUtente,a.idutente)
								--carlo 10/2/20205 ho aggiunto il controllo sul tipo di azione S
							,idmesso=isnull(@idPostino,a.idmesso) --carlo 31/3/2025
								--case 
								--when left(@codfamigliaazione,1) ='F' --and isnull(@Chiedi_Operatore,0)=-1
								--	then isnull(@idPostino,a.idmesso) 
								--else a.idmesso end
							,iddistintareso=case when @CodFamigliaAzione='s' then @IdDistinta
											else a.IdDistintaReso end
							,iddistintaacc=case when @IdAzione=1 then @IdDistinta else a.iddistintaacc end
							,RiferimentoEsterno1=case when @IdAzione=1159 then replace(ElencoParametro1,';','') else a.RiferimentoEsterno1 end	
					from #elenco e
					inner join SPED_ATTIVITA a on a.IdSpedizione=e.idspedizione
					left join SPED_WORKFLOW  w on w.IdAzione=@IdAzione and isnull(w.Stato_Inizio,'') =isnull(a.Stato,'')
					where e.position =@prog

				end

				FETCH NEXT FROM db_cursor INTO @prog 
			END 
			CLOSE db_cursor  
			DEALLOCATE db_cursor 


		commit transaction tr1
		--raiserror ('Errore nel inserimento dei dati',16,1)

		--17/11/2025 Carlo, tolgo a mano eventuali righe doppie, anche se non ho capito come ci finiscono qui
		insert into SPED_SPED2DISTINTE_BACKUP (IdSped2Dist,IdSpedizione,IdDistinta,Progressivo,Stato_Inizio,Stato_Fine,Barcode1,Barcode2,Data,IdUtente,Latitude,Longitude,Nota,IdPalmRaw,Foto,Qualifica,ConsegnatoA,PrecisioneGPS,NoRend)
		select IdSped2Dist,IdSpedizione,IdDistinta,Progressivo,Stato_Inizio,Stato_Fine,Barcode1,Barcode2,Data,IdUtente,Latitude,Longitude,Nota,IdPalmRaw,Foto,Qualifica,ConsegnatoA,PrecisioneGPS,NoRend 
		from SPED_SPED2DISTINTE where IdSped2Dist in (
				select max(idsped2dist)  
				from SPED_SPED2DISTINTE where iddistinta =@IdDistinta
				group by IdSpedizione,IdDistinta 
				having COUNT(*)>1
			)
		delete from SPED_SPED2DISTINTE where IdSped2Dist in (
				select max(idsped2dist)
				from SPED_SPED2DISTINTE where iddistinta =@IdDistinta
				group by IdSpedizione,IdDistinta 
				having COUNT(*)>1
			)


		--Francesco 04/09/2025 - Se è una Distinta Flyer da portare su palmare
		if @IdAzione=1187
			INSERT INTO [PALM_ATTIVITA]
					(idpalmservizio,barcode,DriverAssegnato,cognome,nome,telefono,email,dataprevista,riferimento,stato,tiporiferimento,mittente,testo1,testo2,alttesto1,alttesto2,datacreazione)
			select 
					1 IdPalmServizio
					,d.Barcode
					,''
					,'Flyer' as Cognome
					,'' as nome
					,'' as Telefono
					,'' as Email
					,d.Data as dataprevista
					,CONVERT(VARCHAR(50),d.IdDistinta) AS riferimento
					,'01' stato		
					,4 AS tiporiferimento
					,'' mittente
					,'' testo1
					,'' testo2
					,'' alttesto1
					,'' alttesto2
					,GETDATE()
				from SPED_DISTINTE d
					left join UTENTI driver on driver.IdUtente=d.IdUtente
					inner join SPED_AZIONI az on az.IdAzione=d.IdAzione
					LEFT JOIN PALM_ATTIVITA X ON x.tiporiferimento=0 AND x.Barcode=CONVERT(VARCHAR(50),d.Barcode)
				where 1=1
					and d.IdDistinta =@IdDistinta
					and X.IdAttivita is null


		--se è una distinta di reso devo creare la riga sul palm_attivita
		if @CodFamigliaAzione='S'
		begin				
				set @Comando='CodFamigliaAzione S'	
				insert into PALM_ATTIVITA (IdPalmServizio,Barcode,Cognome,Indirizzo,Cap,Localita,Prov,TipoRiferimento,Riferimento,IdCliente,stato)
				select top 1 2 as idPalmServizio,sd.Barcode,sa.MittenteRagioneSociale,MittenteIndirizzo,MittenteCap,MittenteLocalita,MittenteProvinciaCodice
					,4 as TipoRiferimento,sd.IdDistinta,sa.IdCliente,'01'
				from SPED_DISTINTE sd 
				inner join SPED_AZIONI a on a.IdAzione=sd.IdAzione
				inner join SPED_ATTIVITA sa on sa.IdDistintaReso=sd.IdDistinta
				left join PALM_ATTIVITA pa on pa.TipoRiferimento=4 and pa.Riferimento=sd.IdDistinta
				where 1=1
					and sd.Barcode=@BarcodeDistinta and sd.IdDistinta =@IdDistinta
					and a.CodFamigliaAzione='S'
					and pa.IdAttivita is null
		end

		--determino se il materiale va in una scatola, nel caso aggiorno la distinta della scatola
		if @Scatola is not null
		begin
			select @IdScatola=iddistinta from SPED_DISTINTE where Barcode=@Scatola
			if @IdScatola is not null
			begin
				insert into SPED_SPED2DISTINTE (IdDistinta,IdSpedizione,Stato_Inizio,Stato_Fine)
				select @IdScatola,sd.IdSpedizione,sd.Stato_Fine,sd.Stato_Fine from SPED_SPED2DISTINTE sd where IdDistinta=@IdDistinta
			
				update SPED_DISTINTE set NumeroAtti=(select COUNT(*) from SPED_SPED2DISTINTE where IdDistinta=@IdScatola) where IdDistinta=@IdScatola
				update SPED_ATTIVITA set idscatola=@IdScatola where IdSpedizione in (select IdSpedizione from SPED_SPED2DISTINTE where IdDistinta=@IdDistinta)
			end		
		end 
		

		--se è una distinta di deposito in comune
		if @CodFamigliaAzione='D' or @IdAzione =1109 or @IdAzione=1117
			update SPED_ATTIVITA set IdDistintaDep=@iddistinta where IdDistintaLast=@IdDistinta

		--if @CodFamigliaAzione='D' and @IdAzione in(1109,1117)
		--	update SPED_ATTIVITA set IdDistintaDep=@iddistinta where IdDistintaLast=@IdDistinta

			 



		--se ADER4 e sono riavvio da RACC a NOTIFICHE
		--su quelle che sono diventate notifiche cambio il prodotto e inserisco il numero di raccomandata
		update SPED_ATTIVITA 
			set IdProdotto = 66 
				,RiferimentoEsterno1='51'+right('0000000000'+convert(varchar(20),sa.idspedizione),10)
				,RiferimentoEsterno2='52'+right('0000000000'+convert(varchar(20),sa.idspedizione),10)
			from SPED_ATTIVITA sa
				inner join #elenco e on e.idspedizione=sa.IdSpedizione
			where 1=1
				and sa.Stato = 'RN3'

		--Se è una distinta di postalizzazione devo creare le raccomandate
		if @CodFamigliaAzione='P'
		begin
			set @Comando='CodFamigliaAzione P'
			--exec POSTALIZZA @IdDistinta
			update SPED_ATTIVITA set IdDistintaPost=@iddistinta 
				from SPED_ATTIVITA sa
				inner join #elenco e on e.idspedizione=sa.IdSpedizione
			

			select sa.IdSpedizione,sa.IdProdotto,p.CodFamiglia,sa.IdCliente,sa.IdDistintaLast
			,case when @IdAzione in (1099,1148) then 
				case when sa.NOTA1 IN ('291','292','294','296','299') then 1
					when sa.nota1 IN ('293','295','297','298') then 20 else 1 end
			else sa.IdFiliale end as IdFiliale
			,sa.DestinazioneRagioneSociale,sa.DestinazioneIndirizzo,sa.DestinazioneNumeroCivico,sa.DestinazioneCap,sa.DestinazioneLocalita,sa.DestinazioneProvinciaCodice,sa.DestinazioneNazioneCodice,sa.DestinazioneLatitude,sa.DestinazioneLongitude   
			,sa.MittenteRagioneSociale,sa.MittenteIndirizzo,sa.MittenteCap,sa.MittenteLocalita,sa.MittenteProvinciaCodice,sa.MittenteEmail,sa.MittenteLatitude,sa.MittenteLongitude	
			,sa.IdMittente
			,sd.IdUtente
			--,case when left(sa.stato,1)='9' then p.IdProdottoCollegato
			--	  when left(sa.stato,1)='A' then p.IdProdottoCollegatoTerzi
			--	  else p.IdProdottoCollegato end as IdNuovoProdotto
			into #ElencoRacc
			from SPED_ATTIVITA sa
				inner join PRODOTTI p on p.IdProdotto=sa.IdProdotto
				inner join SPED_DISTINTE sd on sd.IdDistinta=sa.IdDistintapost
				where 1=1
				and sa.IdDistintapost=@IdDistinta
				--and sa.IdProdotto in (12,13,14)
				--and sa.Stato  in ('99','A1')


			declare @numeroatti int
			declare @idlotto int
			declare @idCliente int
			declare @IdProdotto int
			declare @IdNuovoProdotto int
			declare @CodFamiglia varchar(5)
			declare @Sigla varchar(10)=''
			declare @IDFilialeLotto int =0
			declare @IDFilialeLottoNew int =0
			select @numeroatti=count(*) from #ElencoRacc 
			select top 1 @idCliente=idcliente from #ElencoRacc
			select top 1 @IDFilialeLotto=IdFiliale from #ElencoRacc
			select top 1 @IDFilialeLottoNew=q.IdFiliale from (select IdFiliale, COUNT(*) Pezzi from #ElencoRacc group by IdFiliale) q order by pezzi desc

--			select top 1 @IdNuovoProdotto=IdNuovoProdotto from #ElencoRacc
			set @IdNuovoProdotto=@IdProdottoGenerato

			select @IdProdotto=p.IdProdotto,@CodFamiglia=p.CodFamiglia,@Sigla=isnull(p.sigla,'') 
				from PRODOTTI p 
				where p.IdProdotto = @IdNuovoProdotto

			--Francesco 18/07/2024 Aggiungo la Provincia sul NomeLotto
			declare @SiglaProv varchar(3)=''
			select @SiglaProv=isnull('_'+f.Prov,'')
			from SPED_DISTINTE d
				inner join FILIALI f on f.IDFILIALE=d.IdFiliale
			where d.IdDistinta=@iddistinta

			if @IDFilialeLotto<>@IDFilialeLottoNew
				set @IDFilialeLotto=@IDFilialeLottoNew
		
			insert into SPED_LOTTI (Lotto,BarcodeBolla
									,IdCliente
									,DataCarico,DataVideoCodifica,IdFilialeAccettazione,NumeroAtti,CodFamiglia,IdProdotto,IdUtente,DataInserimento)
			select @sigla+'-'+CONVERT(varchar(20),@iddistinta)+@SiglaProv as lotto
					,CONVERT(varchar(20),@iddistinta) as barcodebolla
					,@idCliente
					,@DataAttuale
					,@DataAttuale
					,@IDFilialeLotto
					,@numeroatti
					,@CodFamiglia
					,@IdProdotto
					,@idutente
					,@DataAttuale
			set @idlotto=SCOPE_IDENTITY()
		
			insert into SPED_ATTIVITA 
				(IdLotto,TipoRiferimento,Riferimento,IdCliente,DataCarico,IdProdotto,IdFiliale
				,idfilialedestinazione,idfilialegiacenza
				,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneNumeroCivico,DestinazioneLocalita,DestinazioneCap,DestinazioneProvinciaCodice,DestinazioneNazioneCodice,DestinazioneLatitude,DestinazioneLongitude
				,MittenteRagioneSociale,MittenteIndirizzo,MittenteLocalita,MittenteCap,MittenteProvinciaCodice,MittenteEmail,MittenteLatitude,MittenteLongitude
				,idmittente
				,DataInserimento)
			select 
				@idlotto,0,CONVERT(varchar(50),x.IdSpedizione),x.idCliente,@DataAttuale,@IdProdotto
				--,@IdFiliale
				,@IdFilialeLotto
				,dbo.GetCoperturaFiliale('D',DestinazioneCap,null,null),dbo.GetCoperturaFiliale('G',DestinazioneCap,dbo.getbelfiore(DestinazioneLocalita,DestinazioneProvinciaCodice),@idprodotto)
				,DestinazioneRagioneSociale,DestinazioneIndirizzo,DestinazioneNumeroCivico,DestinazioneLocalita,DestinazioneCap,DestinazioneProvinciaCodice,DestinazioneNazioneCodice,DestinazioneLatitude,DestinazioneLongitude
				,MittenteRagioneSociale,MittenteIndirizzo,MittenteLocalita,MittenteCap,MittenteProvinciaCodice,MittenteEmail,MittenteLatitude,MittenteLongitude
				,idmittente
				,@DataAttuale
			from #elencoRacc x

			--assegna barcode
			update SPED_ATTIVITA
				--se sto generando racc139 allora prendo RifEsterno1, se racc140 allora RifEsterno2 altrimenti genero io il barcode
				--se rifest2 o rifest1 sono nulli, li devo generare
				set Barcode= isnull(case when @IdProdotto in (5) then s_orig.RiferimentoEsterno1
										 when @IdProdotto in (6,7) then case when len(isnull(s_orig.RiferimentoEsterno2,''))>2 
												then s_orig.RiferimentoEsterno2 else '40' +right('0000000000'+CONVERT(varchar(10),SPED_ATTIVITA.IdSpedizione),10) end
										 when @IdProdotto in (8) then s_orig.RiferimentoEsterno3
									end
								  ,case when @IdProdotto is not null then '40' else '39' end+right('0000000000'+CONVERT(varchar(10),SPED_ATTIVITA.IdSpedizione),10)
								  )
					--genero la ricevuta di ritorno, solo per i 140

					,Riferimentoesterno1=case when @IdProdotto=6 and s_orig.IdCliente=5322 then '41'+right(s_orig.RiferimentoEsterno2,10)
										 else '41'+right('0000000000'+CONVERT(varchar(10),SPED_ATTIVITA.IdSpedizione),10) end
					,idListino=case when @IdAzione=1058 and @idCliente=5377 then 368 --139 siracusa
									when @IdAzione=1020 and @idCliente=5377 then 369 --140 siracusa
								else NULL end
				from SPED_ATTIVITA 
				inner join SPED_attivita s_orig on s_orig.IdSpedizione=convert(int,SPED_ATTIVITA.Riferimento)  
				--inner join PRODOTTI p on p.IdProdotto=s_orig.IdProdotto
				where SPED_ATTIVITA.IdLotto=@idlotto

			--setto il collegamento tra la relata e la raccomandata
			UPDATE SPED_ATTIVITA
				SET    IdRacc = racc.IdSpedizione
				FROM  SPED_ATTIVITA 
				INNER JOIN SPED_ATTIVITA AS racc ON racc.TipoRiferimento = 0 AND CONVERT(int, racc.Riferimento) = SPED_ATTIVITA.IdSpedizione
				WHERE (racc.IdLotto = @idlotto)
		end
		

		--se è una distinta di esito finale aggiorno il campo id2esito
		set @Comando='Aggiornamento Id2esito'
		update SPED_ATTIVITA set id2esito =sd.IdSped2Dist
			from sped_attivita sa
			inner join SPED_SPED2DISTINTE sd on sd.IdSpedizione=sa.IdSpedizione
			inner join sped_distinte d on d.iddistinta=sd.iddistinta
			inner join SPED_AZIONI az on az.IdAzione=d.IdAzione
			where d.IdDistinta=@IdDistinta
			and az.esitofinale=-1

		--se l'azione forza la filiale di giacenza o di consegna, devo aggiornare la PALM
		if (isnull(@ForzaFilialeGiacenza,0)=-1 or isnull(@ForzaFilialeDestinazione,0)=-1)
		begin
			set @Comando='Aggiorno Filiale Giacenza'
			exec PALM_AggiornaFiliale @IdDistinta =@IdDistinta 
			--update SPED_DISTINTE set Stato=9 where IdDistinta=@IdDistinta
		end

		--se la distinta è quella di reso cartoline allora genero le RR
		--Francesco 27/05/2026 -- Escludo le raccomandte Spike perchè hanno il barcode Raccomandata uguale al Barcode Cartolina
		if @IdAzione=1035 and @idCliente<>5399 and @IdProdotto<>4
		begin
			exec RR_Crea @iddistinta=@IdDistinta with recompile
		end

		--se la distinta non ha il flag PortaSulPalmare attivo i barcode non devono essere piu visibili sui palmari
		set @Comando='Tolgo da palmare'
		if @EsitoFinale=-1
		begin
			update PALM_ATTIVITA set stato='02'
				from PALM_ATTIVITA pa (nolock)
				inner join sped_attivita sa (nolock) on sa.IdSpedizione=pa.Riferimento 
				inner join SPED_SPED2DISTINTE sd (nolock) on sd.IdSpedizione=sa.IdSpedizione
				inner join sped_distinte d (nolock) on d.iddistinta=sd.iddistinta
				inner join SPED_AZIONI az (nolock) on az.IdAzione=d.IdAzione
				where d.IdDistinta=@IdDistinta
				and pa.TipoRiferimento=0
				and pa.stato='01'
				--and isnull(az.PortaSuPalmare,0)<>-1
		end

		--se la distinta contiene spedizioni di IONE devo appuntarmi i record per poi trasferire i tracking
		if 1=1
		begin
			set @Comando='Spedizioni IONE'
			insert into sped_2ione (idspedizione,IdSped2Dist,Datainserimento)
			select sdd.IdSpedizione,sdd.IdSped2Dist,getdate()
			from SPED_DISTINTE sd
				inner join SPED_AZIONI a on a.IdAzione=sd.IdAzione
				inner join SPED_ATTIVITA sa on sa.IdDistintaLast=sd.IdDistinta
				inner join SPED_SPED2DISTINTE sdd on sdd.IdDistinta =sd.IdDistinta and sdd.IdSpedizione=sa.IdSpedizione
				where 1=1
					and sd.Barcode=@BarcodeDistinta and sd.IdDistinta =@IdDistinta
					and sa.TipoRiferimento=1
		end
		
		declare @PortaSuPALM int = 0
		select @PortaSuPALM=PortaSuPalmare from SPED_AZIONI where IdAzione=@IdAzione
		
		if @PortaSuPALM=-1
		begin
			set @Comando='Porta su Palmare'
			exec PALM_LOAD @iddistinta=@iddistinta with recompile
		end

		--se è un giro non ultimato devo settare a 1 sulla palm_attivita ma toglierlo dal driver attuale
		if @idazione=5
		begin
			UPDATE [PALM_ATTIVITA]
			SET DriverAssegnato=''
				,stato='01'
			from SPED_DISTINTE d (nolock)
			inner join SPED_SPED2DISTINTE sd (nolock) on sd.IdDistinta=d.IdDistinta
			inner join SPED_ATTIVITA sa (nolock) on sa.IdSpedizione=sd.IdSpedizione
			inner JOIN PALM_ATTIVITA X (nolock) ON x.tiporiferimento=0 AND x.riferimento=CONVERT(VARCHAR(50),sa.IdSpedizione)
			where 1=1
			and d.IdDistinta =@IdDistinta
		end



		--TOPPA ADER4
		--SE E' ASSENTE PERSONA FISICA e IN PRECEDENZA HO UNA RICERCA ANAGRAFICA CON VARIAZIONE > MX7
		--SE E' ASSENTE PNF e in precedenza ho un  >MX6
		select sa.idspedizione,sd.idsped2dist as ids1
			,0 as ids2
			,0 as ids3
			,len(sa.destinazionecodicefiscale) as CF
			,sd.Stato_Inizio
			into #tmps1
			from SPED_DISTINTE d
			inner join SPED_SPED2DISTINTE sd on sd.IdDistinta=d.IdDistinta
			inner join SPED_ATTIVITA sa on sa.IdSpedizione=sd.IdSpedizione
			where 1=1
			and d.IdDistinta =@IdDistinta
			and sd.stato_fine='MX8'

			declare  @idspedizione int
				,@ids1 int
				,@cf int
				,@st4 varchar(10)
				,@st3 varchar(10)
			declare @ids2 int=0
			declare @ids3 int=0
			declare @ids4 int=0

			DECLARE db_cur1 CURSOR FOR 
			select IdSpedizione,IdS1,cf from #tmps1 
			OPEN db_cur1  
			FETCH NEXT FROM db_cur1 INTO @idspedizione,@ids1,@CF 				
			WHILE @@FETCH_STATUS = 0 
			begin
					select @ids2=max(idsped2dist) from SPED_SPED2DISTINTE where IdSpedizione=@idspedizione and IdSped2Dist<@ids1 and IdDistinta is not null
					select @ids3=max(idsped2dist) from SPED_SPED2DISTINTE where IdSpedizione=@idspedizione and IdSped2Dist<@ids2 and IdDistinta is not null
					select @ids4=max(idsped2dist) from SPED_SPED2DISTINTE where IdSpedizione=@idspedizione and IdSped2Dist<@ids3 and IdDistinta is not null
					select @st3=Stato_Inizio from SPED_SPED2DISTINTE where IdSped2Dist=@ids3
					select @st4=Stato_Inizio from SPED_SPED2DISTINTE where IdSped2Dist=@ids4
					
					--SE PF e R25
					if @cf=16
					begin
						if @st3='R25' and @cf=16
						begin
							update SPED_SPED2DISTINTE set Stato_Fine='MX7' where IdSped2Dist=@ids1
							update SPED_ATTIVITA set stato='MX7' where IdSpedizione=@idspedizione
						end
					end
					--SE PNF e R38 e R24 prima 
					else if @cf=11
						begin
							if @st4 in ('R38','MN4') and @st3 in ('R24','M24')
							begin
								update SPED_SPED2DISTINTE set Stato_Fine='MX8' where IdSped2Dist=@ids1
								update SPED_ATTIVITA set stato='MX8' where IdSpedizione=@idspedizione
							end
							else
							begin
								update SPED_SPED2DISTINTE set Stato_Fine='MX6' where IdSped2Dist=@ids1
								update SPED_ATTIVITA set stato='MX6' where IdSpedizione=@idspedizione
							end

						end
				FETCH NEXT FROM db_cur1 INTO @idspedizione,@ids1,@CF
			END 
			CLOSE db_cur1  
			DEALLOCATE db_cur1 
			

		--continua il toppone ADER4 
		-- ---------------------------------------------------------------
		-- BLOCCO DISATTIVATO (agosto 2026)
		-- Chiamava dbo.ADER4_VerificaAssenti, funzione che su questo database
		-- non esiste piu': la procedura andava quindi in errore invece di
		-- completare l'inserimento degli esiti.
		-- Riguardava solo le distinte con IdAzione 1105 e 1140 (lavorazioni
		-- ADER4) e ricalcolava lo stato degli assenti con codice fiscale di
		-- persona fisica. Se quella lavorazione dovesse tornare, va prima
		-- ripristinata la funzione e poi tolto il commento qui sotto.
		-- ---------------------------------------------------------------
		/*
		select sa.idspedizione,sd.idsped2dist
			,sa.Stato
			,dbo.ADER4_VerificaAssenti(sa.idspedizione,0) StatoNuovo
			into #tmpx1
			from SPED_DISTINTE d
			inner join SPED_SPED2DISTINTE sd on sd.IdDistinta=d.IdDistinta
			inner join SPED_ATTIVITA sa on sa.IdSpedizione=sd.IdSpedizione
			where 1=1
			and d.IdDistinta =@IdDistinta
			and LEN(sa.DestinazioneCodiceFiscale )=16
			and d.IdAzione in (1105,1140)
		
		update SPED_ATTIVITA set Stato=x.StatoNuovo
		from #tmpx1 x
		inner join sped_attivita sa on sa.idspedizione=x.idspedizione
		and x.StatoNuovo<>x.Stato

		update SPED_SPED2DISTINTE set Stato_fine=x.StatoNuovo
		from #tmpx1 x
		inner join SPED_SPED2DISTINTE sd on sd.IdSped2Dist=x.IdSped2Dist
		and x.StatoNuovo<>x.Stato
		*/

		--fine toppone


		set @Comando='OK'
		set @WebReport=(select top 1 WebReport  from SPED_AZIONI z where z.IdAzione =@IdAzione )
		set @Result='OK'

		if @quiet=0
			select @IdDistinta as iddistinta
				,@BarcodeDistinta as BarcodeDistinta
				,(select COUNT(*) from #elenco) TotAtti
				,@WebReport as webreport
				,@Result as Result



	end try
	begin catch
		if @@TRANCOUNT > 0	
			rollback transaction 
		set @Result ='Errore: '+@comando + ' ' + convert(varchar,ERROR_NUMBER())+ ' ' + ERROR_MESSAGE()
		select @Result as Result
	end catch

END

