-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date, ,>
-- Description:	<Description, ,>
-- =============================================
CREATE FUNCTION [dbo].[SetPunteggio]
(
	-- Add the parameters for the function here
	@Parcel int
	,@Rac140 int
	,@M1_Cons int
	,@M1_AssSco int
	,@M2_Cons int
	,@M2_Ass int
	,@M2_Sco int
	,@Data date
	,@IdFiliale int
)
RETURNS float
AS
BEGIN
	-- Declare the return variable here
	DECLARE @Punteggio float

	declare @Peso int=1
	if @IdFiliale=1268 set @Peso=0

	-- Add the T-SQL statements to compute the return value here
	set @Punteggio=@peso*2.5*isnull(CONVERT(float,@Parcel),0)
					+1*isnull(CONVERT(float,@Rac140),0)
					+2.5*isnull(CONVERT(float,@M1_Cons),0)
					+1*isnull(CONVERT(float,@M1_AssSco),0)
					+2.5*isnull(CONVERT(float,@M2_Cons),0)
					+case when @data<'250301' then 1.5*isnull(CONVERT(float,@M2_Ass),0) else 1*isnull(CONVERT(float,@M2_Ass),0) end
					+case when @data<'250301' then 1.5*isnull(CONVERT(float,@M2_Sco),0) else 2*isnull(CONVERT(float,@M2_Sco),0) end
	-- Return the result of the function
	RETURN @Punteggio

END

