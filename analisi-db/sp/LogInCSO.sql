
-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE PROCEDURE [dbo].[LogInCSO] @CodAppLogIn varchar(100),@utente varchar(250),@pwd varchar(250)=null,@tipo int
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	declare @esiste int
	declare @passW varchar(250)=''
    -- Insert statements for procedure here
	
	if @tipo=0
		SELECT @esiste=count(*)
		from Utenti
		where codAppLogin=@CodAppLogIn and DataFine is null

	if @tipo=1
		select @passW=Pass
		from Utenti
		where Utente=@utente and DataFine is null 

	select isnull(@esiste,0) esiste, @passW passW
END

