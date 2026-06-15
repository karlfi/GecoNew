-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE PROCEDURE [dbo].[ElencoMenuGruppi] 
	@IdUtente int
-- Add the parameters for the stored procedure here
AS
    BEGIN
        -- SET NOCOUNT ON added to prevent extra result sets from
        -- interfering with SELECT statements.
        SET NOCOUNT ON;
	declare @idRuolo int=null

	if @idutente is not null
		select @IdRuolo=idruolo from UTENTI where IdUtente=@IdUtente

	if @IdRuolo is null 
		set @IdRuolo=99


	--genero la tabella temporanea con tutte le righe dei menu e il flag "Attivata" in funzione del RUOLO
	--tolgo solo le righe che hanno disabled=1
	select me.idmenuelemento 
		,me.parentid
		,me.text
		,me.Videata
		,me.Parametri
		,me.navigateurl
		,me.ToolTip
		,me.Icon
		,me.Popup
		,max(case when mr.idruolo IS null then 0 else 1 end) as Attivato
		into #tmp
		from menu_elementi me
		left join menu_elementiruoli lnk on lnk.idmenuelemento=me.idmenuelemento
		left join ruoli mr on mr.idruolo=lnk.idruolo and mr.idruolo=@idruolo
		left join menu_elementi mp on mp.idmenuelemento=me.parentid
		where 1=1
		and ISNULL(me.Disabled,0)=0
		group by me.idmenuelemento 
		,me.parentid
		,me.text
		,me.navigateurl
		,me.Videata
		,me.Parametri
		,me.ToolTip
		,me.Icon
		,me.Popup


	--setto Attivato=1 tutti i menu che rientrano nella condizione del GRUPPO
	update #tmp set Attivato=1 
		from #tmp me
		inner join MENU_ELEMENTIGRUPPI meg on meg.IdMenu=me.IdMenuElemento
		inner join GRUPPI g on g.IdGruppo=meg.IdGruppo
		inner join UTENTI_GRUPPI ug on ug.IdGruppo=g.IdGruppo
		inner join UTENTI u on u.IdUtente=ug.IdUtente and u.IdUtente=@idutente
	where 1=1

	--mi calcolo se per ogni riga ho il padre abilitato o uno qualunque dei figli abilitato
	select x.*,isnull(xpadre.attivato,0) as PadreAttivo
	,isnull((select MAX(Attivato) from #tmp where ParentID=x.IdMenuElemento),0) as FiglioAttivo
	into #tmpDef
	from #tmp x
	left join #tmp as xpadre on xpadre.idmenuelemento=x.parentid


	select me.IdMenuElemento as ID
		,me.ParentID
		,me.Text
		,me.Videata
		,me.Parametri
		,me.NavigateUrl
		,me.ToolTip
		,me.Icon
		,me.Popup
		,case when me.parentid=0 
		then 100-coalesce(me.sorting,me.idmenuelemento)													--Se è un padre prendo il id (del padre) *10000
		else coalesce(mp.sorting,mp.idmenuelemento)*10000 +coalesce(me.sorting,me.idmenuelemento)*100	--se è un figlio prendo l'id del padre *10000 + id del figlio (che deve essere <100) 
	end as sorting																						--se sortin è valorizzato sostituisce l'id
	from #tmpDef xdef
	inner join menu_elementi me on me.IdMenuElemento =xdef.IdMenuElemento
	left join menu_elementi mp on mp.idmenuelemento=me.parentid
	where Attivato +PadreAttivo+FiglioAttivo>0

	order by sorting 


    END;
