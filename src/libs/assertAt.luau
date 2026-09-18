--!native
--!optimize 2

const function assertAtLevel(condition: any, message: string, level: number?)
	if not condition then
		-- hi if this errors click on the last part of log
		-- brings you to the actual erroring line :)
		error(message, (level or 1) + 1)
	end
end
return assertAtLevel