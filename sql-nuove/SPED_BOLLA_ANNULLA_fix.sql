-- =============================================================
-- FIX della SP legacy SPED_BOLLA_ANNULLA (annullo bolle di trasferimento).
--
-- Problema: SPED_BOLLA inserisce la bolla con stato NULL; la condizione
-- "stato <> '0X'" (ANSI_NULLS ON) valuta NULL <> '0X' = UNKNOWN, quindi la
-- riga veniva esclusa e la SP restituiva sempre "Spedizione non annullabile"
-- sulle bolle appena create.
--
-- Correzione: ISNULL(stato,'') <> '0X'. Nient'altro cambia. La SP resta la
-- stessa usata anche dall'app InDe (nessun duplicato): il fix vale per tutti.
-- Idempotente (ALTER).
-- =============================================================
ALTER PROCEDURE SPED_BOLLA_ANNULLA
	@IdSpedizione int
	,@idutente int = null
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    -- Insert statements for procedure here
	declare @messaggio varchar(100)
	declare @barcode varchar(50)
	select @barcode=barcode
		from sped_Attivita
		where idspedizione=@idspedizione and left(barcode,2)='61'
		and ISNULL(stato,'') <>'0X'   -- FIX: le bolle appena create hanno stato NULL
		and DataCarico >convert(date,getdate())

	if left(isnull(@barcode,''),2)<>'61'
		set @messaggio='Spedizione non annullabile'
	else
	begin
		update SPED_ATTIVITA set stato='0X',IdUtente =isnull(@idutente,idutente) where IdSpedizione=@IdSpedizione
		set @messaggio='Comando eseguito correttamente'
	end
	select @messaggio msg,@messaggio as Messaggio,'' as nulla


END
GO
