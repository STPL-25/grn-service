import express from "express";
import StockRequestController from "./stockrequest.controller.js";

const StockRequestRouter = express.Router();

// Requests (requester + stock incharge share the list endpoint; the
// requester's page filters with ?requested_by=<own ecno>)
StockRequestRouter.get("/getRequests",                    StockRequestController.getRequests);
StockRequestRouter.get("/getRequestItems/:request_sno",   StockRequestController.getRequestItems);
StockRequestRouter.post("/createRequest",                 StockRequestController.createRequest);

// Stock-incharge actions
StockRequestRouter.post("/issueRequest",                  StockRequestController.issueRequest);
StockRequestRouter.put("/rejectRequest/:request_sno",     StockRequestController.rejectRequest);

// Requester action
StockRequestRouter.put("/cancelRequest/:request_sno",     StockRequestController.cancelRequest);

export default StockRequestRouter;
