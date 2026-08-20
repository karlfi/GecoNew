-- =============================================================
-- Tracking - indirizzo del report server
--
-- Un link al PDF erano composti con cruscotto.speedyworld.it, che non e' piu'
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



-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[Tracking] 
	@barcode varchar(200)
	,@IdCliente int =null
WITH RECOMPILE 
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    declare  @IdSped int = null
	declare @TipoBarcode int=0
	declare @logo varchar(max)=''
	declare @CodFamiglia varchar(1)

	set @barcode=RIGHT(@barcode,50)

	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1,@IdCliente=IdCliente from SPED_ATTIVITA where Barcode=@Barcode
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=2,@IdCliente=IdCliente from SPED_ATTIVITA s inner join PRODOTTI pr on pr.IdProdotto=s.IdProdotto where RiferimentoEsterno1=@Barcode and pr.CodFamiglia in ('R','P')
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=3,@IdCliente=IdCliente from SPED_ATTIVITA where RiferimentoEsterno2=@Barcode
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=3,@IdCliente=IdCliente from SPED_ATTIVITA where RiferimentoEsterno3=@Barcode
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1,@IdCliente=IdCliente from SPED_ATTIVITA where RiferimentoSpedizione=@Barcode
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1,@IdCliente=IdCliente from SPED_ATTIVITA where NOTA2=@Barcode
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=1,@IdCliente=IdCliente from SPED_ATTIVITA where CodiceRMN=@Barcode
	if @IdSped is null and PATINDEX('%@%',@barcode)=0
		select @IdSped=IdSpedizione,@TipoBarcode=4,@IdCliente=IdCliente from SPED_ATTIVITA where RiferimentoEsterno1=@Barcode

	
	if PATINDEX('%@%',@barcode)=0
		select @logo='C:\Progetti\DeliveryWeb\csharp\csharp\images\Azienda_'+convert(varchar(100),IdAzienda)+'.png' from CLIENTI where IdCliente=@IdCliente 
	else
		select @logo='C:\Progetti\DeliveryWeb\csharp\csharp\images\Azienda_'+convert(varchar(100),IdAzienda)+'.png' from CLIENTI where IdCliente=5306

	declare @spari int
	declare @datacarico smalldatetime

	if @IdSped is null and PATINDEX('%@%',@barcode)=0
	begin
		select @spari=COUNT(*),@datacarico=min(datacreazione) from PALM_RAW where barcode=@Barcode
		if @spari>0
			select	@barcode as barcode,
					'SPEDIZIONE NON PRESENTE' DestinazioneRagioneSociale,
					'' DestinazioneIndirizzo ,
					'' Comune,
					''Descrizione,
					''Prodotto,
					''lotto,
					convert(varchar(20),@datacarico,113) as DataCarico,
					'' Foto,
					'' FirmaPostino
					,0.0 as Latitude
					,0.0 as Longitude
					,@logo FileLogo
					
	end

	if @IdSped is null and PATINDEX('%@%',@barcode)>0
	begin
		declare @LastPos int

		select @spari=COUNT(*),@datacarico=min(datacreazione) from PALM_RAW where barcode=@barcode
		select @LastPos=max(id) from PALM_RAW where Barcode=@barcode

		select	@barcode as barcode,
				f.FILIALE DestinazioneRagioneSociale,
				f.Indirizzo DestinazioneIndirizzo ,
				f.CAP+' '+f.Comune Comune,
				te.Evento Descrizione,
				pa.Cognome Prodotto,
				'SCATOLA' lotto,
				convert(varchar(20),@datacarico,113) as DataCarico,
				'' Foto,
				'' FirmaPostino
				,isnull(f.Latitude,0.0) as Latitude
				,isnull(f.Longitude,0.0) as Longitude
				,@logo FileLogo
				,'' Giacenza
				,'' Distribuzione
				,'' Cliente
				,'' Mittente
		from PALM_ATTIVITA pa
			inner join PALM_RAW pr on pa.Barcode=pr.barcode and pr.id=@LastPos
			inner join UTENTI u on u.codAppLogin=pr.driver
			inner join FILIALI f on f.IDFILIALE=u.IdFiliale
			inner join PALM_TIPOEVENTO te on te.tipoEventoCodice=pa.tipoEventoCodice
		where pa.barcode=@barcode
	end

	
	if @IdSped is not null
		select	case when isnull(s.RiferimentoEsterno1,'')>'' and p.CodFamiglia in ('P','R') then s.barcode+' - AR : '+case when s.IdProdotto=11 then s.CodiceRMN else s.RiferimentoEsterno1 end
					when sRR.Barcode IS Not null and p.CodFamiglia='R' and s.IdCliente<>5318 then s.barcode+' - AR : '+sRR.Barcode
					when sRACC.Barcode IS Not null then sRACC.Barcode+' - AR : '+s.Barcode
					when isnull(s.RiferimentoEsterno1,'')>'' and p.CodFamiglia in ('A') then s.barcode+' - AR : '+s.RiferimentoEsterno1
					else s.Barcode end barcode,
				s.DestinazioneRagioneSociale+isnull(' - C.F. '+s.DestinazioneCodiceFiscale,'') DestinazioneRagioneSociale,
				ISNULL(s.DestinazioneIndirizzo + ' ', '') + ISNULL(s.DestinazioneNumeroCivico, '') as DestinazioneIndirizzo ,
				s.DestinazioneCap+' '+s.DestinazioneLocalita+' '+isnull(s.DestinazioneProvinciaCodice,'') Comune,
				s.stato+' - '+case when s.IdProdotto=66 and s.Stato in ('MT1','MT2','MT3','M03') then isnull(sd.Nota,st.Descrizione)+' '+isnull(s.ConsegnatoA,'')+' '+isnull(s.Qualifica,'')
									when s.IdProdotto=12 and s.Stato in ('A1','A2','A3') then isnull(sd.Nota,st.Descrizione)+' '+isnull(s.Qualifica,'')							
				else
					isnull(sd.Nota,st.Descrizione)
				end +' del '+CONVERT(varchar(10),s.datastato,103) Descrizione,
				--case when ISNULL(pa1.tipoEventoCodice,'')='S_002' then 
				--	'<a title="Visuliazza Ricevuta firmata" href="http://192.168.0.176:8097/result?report=DELIVERY_RicevutaFirmata.fr3&format=PDF&idspedizione='+convert(varchar(50),s.IdSpedizione)+'" target="_blank" >'+isnull(sd.Nota,st.Descrizione)+'</a>'
				--	else isnull(sd.Nota,st.Descrizione) 
				--end Descrizione,
				case when s.IdCliente=5318 then fl.Descrizione else p.Prodotto end Prodotto,
				l.lotto,
				convert(varchar(20),isnull(s.dataordine,s.DataCarico),113) as DataCarico ,
				isnull(sd.Foto,'') Foto,
				u.CodiceFiscale+'.jpg' FirmaPostino
				,isnull(sd.Latitude,s.destinazionelatitude) as Latitude
				,isnull(sd.Longitude,s.destinazionelongitude) as Longitude
				,@logo FileLogo
				--,case when (ISNULL(@idcliente,0)=0 or (ISNULL(@idcliente,0)<>0 and s.stato in ('99','95','9g'))) then
				--	left(isnull(fgiac.FILIALE+' '+fgiac.Indirizzo+' '+fgiac.CAP+' '+fgiac.Comune,''),250) 
				--	else '' end
				--	as Giacenza
				,left(isnull(fgiac.FILIALE+' '+fgiac.Indirizzo+' '+fgiac.CAP+' '+fgiac.Comune,''),250) Giacenza
				,left(isnull(fdist.FILIALE+' '+fdist.Indirizzo+' '+fdist.CAP+' '+fdist.Comune,''),250) Distribuzione
				,replace(isnull(s.NOTA2,''),';','') Nota2
				,c.RagioneSociale Cliente
				,case when mit.IdMittente is not null then mit.UFFICIOSPEDITORE
				 else isnull(s.MittenteRagioneSociale,'')
				 end Mittente
		from SPED_ATTIVITA s
			inner join CLIENTI c on c.IdCliente=s.IdCliente
			left join SPED_ATTIVITA sRR on sRR.TipoRiferimento=8 and convert(int,sRR.riferimento)=s.IdSpedizione
			LEFT join SPED_ATTIVITA sRACC on s.TipoRiferimento=8 and convert(int,s.Riferimento)=sRACC.IdSpedizione
			left join FATT_LISTINI fl on fl.IdListino=s.idListino
			left join PALM_ATTIVITA pa1 on pa1.Barcode=s.Barcode
			left join FILIALI fgiac on fgiac.IDFILIALE=s.IdFilialeGiacenza 
			left join FILIALI fdist on fdist.IDFILIALE=s.IdFilialeDestinazione
			left join SPED_STATI st on st.STATO=s.Stato 
			left join SPED_LOTTI l on l.IdLotto=s.IdLotto 
			left join PRODOTTI p on p.IdProdotto=s.IdProdotto 
			left join SPED_SPED2DISTINTE sd on sd.IdSpedizione =s.IdSpedizione and s.Stato=sd.Stato_Fine and st.Descrizione=sd.Nota

			left join SPED_SPED2DISTINTE sd2 on sd2.IdDistinta=s.IdDistintaLast and sd2.idspedizione=s.idspedizione
			left join SPED_DISTINTE d on d.IdDistinta=sd2.IdDistinta
			left join SPED_AZIONI sa on sa.IdAzione=d.IdAzione

			left join PALM_ATTIVITA pa on pa.idPalmFineGita=sd.IdPalmRaw
			left join UTENTI u on sd.IdUtente=u.IdUtente

			left join MITTENTI mit on mit.IdMittente=s.IdMittente
		where s.IdSpedizione=@IdSped
			and s.IdCliente = ISNULL(@idcliente,s.idcliente)
	
END

