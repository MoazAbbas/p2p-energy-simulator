
import express, { Request, Response } from "express";

const app = express();
const port = 3001;

app.use(express.json());

app.get("/api/health", (_req: Request, res: Response) => {
  res.json({
    status: "ok", 
    application: "p2p-energy",
    mode: "simulation",
  });
});

app.listen(port, () => {
  console.log(`Backend running at http://localhost:${port}`);
});
